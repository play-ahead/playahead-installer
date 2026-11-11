#!/usr/bin/env bash
# shellcheck shell=bash
#
# ============================================================
# testes/trava-versoes.sh
#
# Trava da rotina semanal de versões. Um pedido de atualização
# (pull request) vindo de uma branch claude/versoes-* só pode
# trocar número de versão. Este script lê o que o pedido altera
# e reprova qualquer coisa fora disso.
#
# Uso, na raiz do repositório:
#
#     RAMO=claude/versoes-2026-11-16 \
#         bash testes/trava-versoes.sh <commit base> <commit do pedido>
#
# O que um pedido da rotina pode alterar:
#
#   - nos três arquivos de lib/ que guardam versão, só a linha da
#     variável e o bloco de comentário logo acima dela;
#   - no template do compose, só as linhas que trazem a imagem;
#   - no CLAUDE.md, só o número de versão e a data dentro de linhas
#     que já existem. Linha nova, linha apagada e texto trocado são
#     reprovados: o CLAUDE.md é instrução para as próximas execuções
#     da rotina e para o Claude deste projeto, e um pedido que
#     pudesse escrever nele à vontade deixaria uma ordem plantada;
#   - o dist/, que o build regenera. Ele não é conferido aqui: o
#     outro workflow roda ./build.sh --check, e como este script
#     não deixa o pedido mexer no build.sh nem no workflow, um
#     dist/ em dia só pode ter saído do lib/ e do template.
#
# O número novo tem de casar com o padrão exato da ferramenta, com
# o nome oficial da imagem e na mesma linha principal: Traefik v3,
# Portainer 2, Mautic 7 (-apache) e MariaDB 10.11. E não pode ser
# menor que o atual: voltar versão traria de volta as falhas que a
# versão atual corrigiu.
#
# Este script roda a partir do main, e não do pedido (o workflow
# usa pull_request_target), para que o pedido não consiga trocar a
# própria trava. O conteúdo do pedido é lido como dado, pelo git
# diff, e nunca é executado.
#
# Pedido de qualquer outra branch passa direto: a trava é só para
# o que a rotina abre sozinha.
# ============================================================

set -euo pipefail

BASE="${1:?uso: trava-versoes.sh <commit base> <commit do pedido>}"
PEDIDO="${2:?uso: trava-versoes.sh <commit base> <commit do pedido>}"
RAMO="${RAMO:-}"

case "$RAMO" in
claude/versoes-*) ;;
*)
	printf 'Branch "%s": não é da rotina de versões. A trava não se aplica.\n' "$RAMO"
	exit 0
	;;
esac

printf 'Branch "%s": pedido da rotina de versões. Conferindo o que ele altera.\n\n' "$RAMO"

FALHAS=0
falhou() {
	printf '  REPROVADO  %s\n' "$*"
	FALHAS=$((FALHAS + 1))
}
ok() { printf '  ok         %s\n' "$*"; }

# Variável de versão por arquivo, com o padrão exato do valor.
# Formato de cada entrada: arquivo|variável|expressão do valor.
VARIAVEIS=(
	'lib/traefik_instalar.sh|PA_TRAEFIK_VERSAO|v3\.[0-9]+\.[0-9]+'
	'lib/portainer.sh|PA_PORTAINER_VERSAO|2\.[0-9]+\.[0-9]+'
	'lib/mautic.sh|PA_MAUTIC_IMAGEM_RECOMENDADA|mautic/mautic:7\.[0-9]+\.[0-9]+-apache'
	'lib/mautic.sh|PA_MARIADB_IMAGEM|mariadb:10\.11\.[0-9]+'
)

TEMPLATE="templates/docker-compose-mautic7-playahead.yml"

# Linhas do template que podem mudar, inteiras.
LINHAS_TEMPLATE='^(#      MAUTIC_IMAGE=mautic/mautic:7\.[0-9]+\.[0-9]+-apache|#      MARIADB_IMAGE=mariadb:10\.11\.[0-9]+|    image: \$\{MAUTIC_IMAGE:-mautic/mautic:7\.[0-9]+\.[0-9]+-apache\}|    image: \$\{MARIADB_IMAGE:-mariadb:10\.11\.[0-9]+\})$'

# ------------------------------------------------------------
# 1. Só os arquivos da lista, e só alterados
# ------------------------------------------------------------

permitido() {
	case "$1" in
	lib/traefik_instalar.sh | lib/portainer.sh | lib/mautic.sh) return 0 ;;
	"$TEMPLATE" | CLAUDE.md) return 0 ;;
	dist/base.sh | dist/mautic7.sh | dist/playahead.sh) return 0 ;;
	esac
	return 1
}

ALTERADOS=()
while IFS=$'\t' read -r dados caminho; do
	[[ -n "$dados" ]] || continue
	# dados: ":modo_antigo modo_novo id_antigo id_novo situação"
	read -r modo_antigo modo_novo _ _ situacao <<<"${dados#:}"
	if ! permitido "$caminho"; then
		falhou "altera ${caminho}, que a rotina não pode tocar"
		continue
	fi
	if [[ "$situacao" != "M" ]]; then
		falhou "${caminho}: só alteração é aceita (situação ${situacao})"
		continue
	fi
	if [[ "$modo_antigo" != "$modo_novo" ]]; then
		falhou "${caminho}: muda o modo do arquivo (${modo_antigo} para ${modo_novo})"
		continue
	fi
	ALTERADOS+=("$caminho")
done < <(git diff --raw --no-renames "$BASE" "$PEDIDO")

if [[ "${#ALTERADOS[@]}" -eq 0 && "$FALHAS" -eq 0 ]]; then
	ok "o pedido não altera nenhum arquivo"
fi

# Um byte nulo no meio do arquivo faz o git tratá-lo como binário e
# responder "Binary files differ", sem linha nenhuma. As conferências
# abaixo leem linhas: sem elas, aprovariam o que não viram.
while IFS=$'\t' read -r mais menos caminho; do
	if [[ "$mais" == "-" || "$menos" == "-" ]]; then
		falhou "${caminho}: o git vê o arquivo como binário; não há como conferir"
	fi
done < <(git diff --numstat --no-renames "$BASE" "$PEDIDO")

foi_alterado() {
	local a
	for a in "${ALTERADOS[@]}"; do
		[[ "$a" == "$1" ]] && return 0
	done
	return 1
}

# ------------------------------------------------------------
# 2. Em lib/, só a variável e o comentário logo acima dela
# ------------------------------------------------------------

# faixas_permitidas <commit> <arquivo>
#
# Imprime "inicio fim" para cada trecho que pode mudar: a linha da
# variável de versão mais as linhas de comentário coladas acima
# dela. Comentário em outro ponto do arquivo fica de fora de
# propósito: dentro de um heredoc, uma linha que começa com "#" é
# conteúdo de arquivo gerado, e não comentário.
faixas_permitidas() {
	local commit="$1" arquivo="$2" entrada var
	local nomes=""
	for entrada in "${VARIAVEIS[@]}"; do
		[[ "${entrada%%|*}" == "$arquivo" ]] || continue
		var="${entrada#*|}"
		var="${var%%|*}"
		nomes+="${var} "
	done
	git show "${commit}:${arquivo}" | awk -v nomes="$nomes" '
		BEGIN { n = split(nomes, lista, " ") }
		{
			linha[NR] = $0
			for (i = 1; i <= n; i++) {
				if (index($0, lista[i] "=") == 1) alvo[NR] = 1
			}
		}
		END {
			for (l = 1; l <= NR; l++) {
				if (!(l in alvo)) continue
				inicio = l
				while (inicio > 1 && linha[inicio - 1] ~ /^#/) inicio--
				# Variáveis coladas uma na outra dividem o mesmo bloco.
				while (inicio > 1 && ((inicio - 1) in alvo)) {
					inicio--
					while (inicio > 1 && linha[inicio - 1] ~ /^#/) inicio--
				}
				print inicio, l
			}
		}'
}

# dentro <inicio> <quantidade> <faixas>
#
# Verdadeiro quando o trecho inteiro cabe numa das faixas.
dentro() {
	local inicio="$1" quantidade="$2" faixas="$3" a b fim
	[[ "$quantidade" -eq 0 ]] && return 0
	fim=$((inicio + quantidade - 1))
	while read -r a b; do
		[[ -n "$a" ]] || continue
		if [[ "$inicio" -ge "$a" && "$fim" -le "$b" ]]; then
			return 0
		fi
	done <<<"$faixas"
	return 1
}

conferir_lib() {
	local arquivo="$1" faixas_antes faixas_depois cabecalho
	local ini_a qtd_a ini_n qtd_n ruim=0
	faixas_antes="$(faixas_permitidas "$BASE" "$arquivo")"
	faixas_depois="$(faixas_permitidas "$PEDIDO" "$arquivo")"

	while read -r cabecalho; do
		# @@ -a,b +c,d @@   (b e d somem quando valem 1)
		[[ "$cabecalho" =~ ^@@\ -([0-9]+)(,([0-9]+))?\ \+([0-9]+)(,([0-9]+))?\ @@ ]] || continue
		ini_a="${BASH_REMATCH[1]}"
		qtd_a="${BASH_REMATCH[3]:-1}"
		ini_n="${BASH_REMATCH[4]}"
		qtd_n="${BASH_REMATCH[6]:-1}"
		if ! dentro "$ini_a" "$qtd_a" "$faixas_antes" ||
			! dentro "$ini_n" "$qtd_n" "$faixas_depois"; then
			falhou "${arquivo}: altera a linha ${ini_n}, fora da variável de versão e do comentário dela"
			ruim=1
		fi
	done < <(git diff -U0 --no-renames "$BASE" "$PEDIDO" -- "$arquivo" | grep '^@@')

	if [[ "$ruim" -eq 0 ]]; then
		ok "${arquivo}: só a variável de versão e o comentário dela"
	fi
}

for arquivo in lib/traefik_instalar.sh lib/portainer.sh lib/mautic.sh; do
	if foi_alterado "$arquivo"; then
		conferir_lib "$arquivo"
	fi
done

# ------------------------------------------------------------
# 3. O valor de cada variável, no pedido, casa com o padrão exato
# ------------------------------------------------------------

for entrada in "${VARIAVEIS[@]}"; do
	IFS='|' read -r arquivo var padrao <<<"$entrada"
	linhas="$(git show "${PEDIDO}:${arquivo}" | grep -E "^${var}=" || true)"
	if [[ "$(printf '%s\n' "$linhas" | grep -c .)" -ne 1 ]]; then
		falhou "${arquivo}: ${var} tem de aparecer uma vez só"
		continue
	fi
	if ! [[ "$linhas" =~ ^${var}=\"(${padrao})\"$ ]]; then
		falhou "${var}: valor fora do padrão aceito (${linhas})"
		continue
	fi
	novo="${BASH_REMATCH[1]}"

	# Não pode voltar versão. O valor de antes vem do commit base.
	antes="$(git show "${BASE}:${arquivo}" | sed -n "s/^${var}=\"\(.*\)\"\$/\1/p" | head -n 1)"
	if [[ -n "$antes" && "$antes" != "$novo" ]] &&
		[[ "$(printf '%s\n%s\n' "$antes" "$novo" | sort -V | tail -n 1)" != "$novo" ]]; then
		falhou "${var}: ${novo} é menor que o atual, ${antes}"
		continue
	fi

	ok "${var} = ${novo}"
done

# ------------------------------------------------------------
# 4. No template, só as linhas da imagem
# ------------------------------------------------------------

# linhas_do_diff <arquivo>
#
# As linhas acrescentadas e removidas, com o sinal na frente, e nada
# do cabeçalho. O cabeçalho do diff acaba no primeiro "@@": pular
# toda linha que começa com "+++" ou "---" deixaria passar uma linha
# nova que começasse com "++".
linhas_do_diff() {
	git diff -U0 --no-renames "$BASE" "$PEDIDO" -- "$1" |
		awk '/^@@/ { corpo = 1; next } corpo && /^[+-]/'
}

if foi_alterado "$TEMPLATE"; then
	ruim=0
	while IFS= read -r linha; do
		if ! [[ "${linha:1}" =~ $LINHAS_TEMPLATE ]]; then
			falhou "${TEMPLATE}: altera linha que não é de imagem: ${linha:0:70}"
			ruim=1
		fi
	done < <(linhas_do_diff "$TEMPLATE")
	if [[ "$ruim" -eq 0 ]]; then
		ok "${TEMPLATE}: só as linhas da imagem"
	fi
fi

# ------------------------------------------------------------
# 5. No CLAUDE.md, só número de versão e data em linha que já existe
# ------------------------------------------------------------

# sem_versoes
#
# Troca cada número de versão e cada data por um marcador. Se o que
# sobra das linhas removidas é igual ao que sobra das acrescentadas,
# o pedido só trocou números.
sem_versoes() {
	sed -E \
		-e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}/DATA/g' \
		-e 's/v?[0-9]+\.[0-9]+\.[0-9]+(-apache)?/VERSAO/g'
}

if foi_alterado "CLAUDE.md"; then
	removidas="$(linhas_do_diff CLAUDE.md | grep '^-' | cut -c2- | sem_versoes || true)"
	acrescentadas="$(linhas_do_diff CLAUDE.md | grep '^+' | cut -c2- | sem_versoes || true)"

	if [[ "$removidas" == "$acrescentadas" ]]; then
		ok "CLAUDE.md: só números de versão e datas, em linhas que já existiam"
	else
		falhou "CLAUDE.md: muda mais que número de versão e data"
		diff <(printf '%s\n' "$removidas") <(printf '%s\n' "$acrescentadas") |
			grep '^[<>]' | head -n 6 | cut -c1-110 | sed 's/^/             /'
	fi
fi

# ------------------------------------------------------------
# Veredito
# ------------------------------------------------------------

printf '\n'
if [[ "$FALHAS" -gt 0 ]]; then
	printf 'Trava: %s problema(s). A rotina de versões só pode trocar número de\n' "$FALHAS"
	printf 'versão. Se a mudança é necessária, ela entra por outro pedido, feito\n'
	printf 'por uma pessoa, numa branch que não seja claude/versoes-*.\n'
	exit 1
fi
printf 'Trava: o pedido só troca versões.\n'
