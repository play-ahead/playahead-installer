#!/usr/bin/env bash
# shellcheck shell=bash
#
# ============================================================
# build.sh
# Gera os artefatos de dist/ a partir de lib/*.sh.
#
# O código-fonte é modular, mas o que é publicado são arquivos
# únicos: um script baixado sozinho por curl não consegue dar
# source em arquivos que não existem na VPS.
#
# Dois alvos hoje:
#     dist/base.sh      Docker, Traefik e Portainer
#     dist/mautic7.sh   Mautic 7
#
# USO
#     ./build.sh            gera os dois
#     ./build.sh --check    só verifica se dist/ está em dia
#                           (para CI e para o hook de commit)
# ============================================================

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

# ------------------------------------------------------------
# Configuração
# ------------------------------------------------------------

# Dois alvos, declarados lado a lado. NÃO é um sistema genérico de
# alvos: quando o terceiro instalador existir, ele se acrescenta
# copiando cinco linhas. Diretório targets/, manifesto e laço sobre
# uma lista de alvos externa ficam de fora até que haja motivo.
#
# A ORDEM DAS LIBS IMPORTA. Não é alfabética, é a ordem de
# dependência: ui primeiro porque todo mundo usa ui_fatal, e o
# orquestrador por último porque é quem chama todos os outros.
#
# Cada artefato leva só o que usa. O instalador de ferramenta
# detecta Docker e Traefik mas não os instala, então os módulos de
# instalação, a descoberta de portas e o swap não entram nele.

PA_ALVOS=(base mautic7)

# Saída e template por alvo em array associativo, e não em nome de
# variável montado em tempo de execução: assim o shellcheck
# consegue rastrear o uso. Só as listas de libs ficam como arrays
# separados, porque array dentro de array não existe em bash.
declare -A PA_SAIDA=(
	[base]="dist/base.sh"
	[mautic7]="dist/mautic7.sh"
)

# A base não tem template: os composes do Traefik e do Portainer
# são gerados em código, porque dependem de valores descobertos em
# execução.
declare -A PA_TEMPLATE=(
	[base]=""
	[mautic7]="templates/docker-compose-mautic7-playahead.yml"
)

# Lidas por nameref em gerar(); o shellcheck não enxerga uso por
# nameref, daí a diretiva.
# shellcheck disable=SC2034
PA_LIBS_base=(
	ui
	checks
	portas
	sistema
	docker
	docker_instalar
	traefik
	traefik_instalar
	cenario
	portainer
	base_main
)

# shellcheck disable=SC2034
PA_LIBS_mautic7=(
	ui
	checks
	docker
	traefik
	cenario
	mautic
	mautic_main
)

PA_FONTE="https://github.com/play-ahead/playahead-installer"

# Delimitador do heredoc que embute o template. Precisa ser algo
# que não apareça dentro do próprio template; o build confere.
PA_DELIM="PA_FIM_DO_TEMPLATE_MAUTIC"

# ------------------------------------------------------------
# Mensagens
# ------------------------------------------------------------

erro() {
	printf 'build: %s\n' "$*" >&2
	exit 1
}

info() {
	printf 'build: %s\n' "$*"
}

# ------------------------------------------------------------
# Leitura do fonte
#
# Fonte única: versão e nome da ferramenta vivem no orquestrador de
# cada alvo, e o build só propaga. Ter esses valores em dois
# lugares é como não ter nenhum dos dois.
#
# O orquestrador é sempre a última lib da lista do alvo, o que
# também documenta a ordem de dependência.
# ------------------------------------------------------------

# orquestrador_de <alvo>
orquestrador_de() {
	local alvo="$1"
	local -n libs="PA_LIBS_${alvo}"

	printf 'lib/%s.sh\n' "${libs[-1]}"
}

# ler_var <nome> <arquivo>
ler_var() {
	local nome="$1"
	local arquivo="$2"
	local valor

	valor="$(
		awk -F'"' -v n="^${nome}=" '$0 ~ n {print $2; exit}' "$arquivo"
	)"

	[[ -n "$valor" ]] || erro "não achei ${nome} em ${arquivo}"

	printf '%s\n' "$valor"
}

# ------------------------------------------------------------
# Geração
# ------------------------------------------------------------

# gerar <alvo> <arquivo_destino> <build>
gerar() {
	local alvo="$1"
	local destino="$2"
	local build="$3"

	local -n libs="PA_LIBS_${alvo}"

	local template="${PA_TEMPLATE[$alvo]}"

	local orq
	orq="$(orquestrador_de "$alvo")"

	local versao ferramenta
	versao="$(ler_var PA_VERSAO "$orq")"
	ferramenta="$(ler_var PA_FERRAMENTA "$orq")"

	local lib
	for lib in "${libs[@]}"; do
		[[ -f "lib/${lib}.sh" ]] || erro "falta lib/${lib}.sh"
	done

	if [[ -n "$template" ]]; then
		[[ -f "$template" ]] || erro "falta $template"

		if grep -qF "$PA_DELIM" "$template"; then
			erro "o template contém ${PA_DELIM}; troque o delimitador"
		fi
	fi

	{
		# O cabeçalho é o mesmo bloco de licença e aviso que o
		# script imprime na tela, mais os dados de versão. Quem dá
		# `less` vê isso nas primeiras linhas, o que é justamente o
		# ponto daquele passo do tutorial.
		cat <<CABECALHO
#!/usr/bin/env bash
# ============================================================
# PLAY AHEAD INSTALLER
# ${ferramenta}
# https://playahead.com.br
# Fabio Roger de Oliveira ME | CNPJ 31.176.090/0001-08
#
# Versão: ${versao}
# Build:  ${build}
# Fonte:  ${PA_FONTE}
#
# Licença MIT. Consulte o arquivo LICENSE.
#
# AVISO
# Este script altera a configuração do servidor onde é executado:
# instala pacotes, cria containers, volumes e regras de rede.
# Execute apenas em servidor dedicado a esta finalidade e do qual
# você tenha cópia de segurança.
#
# O software é fornecido "como está", sem garantia de qualquer
# espécie. A Play Ahead não se responsabiliza por perda de dados,
# indisponibilidade ou danos decorrentes do uso.
#
# Leia o código antes de executar.
# ============================================================
#
# ARQUIVO GERADO POR build.sh. NÃO EDITE AQUI.
# O código-fonte é modular e vive em lib/*.sh, em ${PA_FONTE}
# ============================================================

set -euo pipefail

CABECALHO

		# As libs, na ordem de dependência. O shebang de cada uma é
		# removido: no meio de um arquivo ele seria só um
		# comentário, mas deixá-lo sugeriria que aquele trecho é
		# executável por conta própria.
		for lib in "${libs[@]}"; do
			printf '# ============================================================\n'
			printf '# lib/%s.sh\n' "$lib"
			printf '# ============================================================\n\n'
			sed '1{/^#!/d}' "lib/${lib}.sh"
			printf '\n'
		done

		# O template do compose, embutido como heredoc citado.
		# Citado é obrigatório: o template está cheio de variáveis
		# do compose que precisam chegar literais ao arquivo final.
		#
		# A base não tem template: os composes do Traefik e do
		# Portainer são gerados em código, porque dependem de
		# valores descobertos em execução.
		if [[ -n "$template" ]]; then
			printf '# ============================================================\n'
			printf '# Template do compose, embutido pelo build.sh\n'
			printf '# ============================================================\n\n'
			printf 'mautic_template_embutido() {\n'
			printf "\tcat <<'%s'\n" "$PA_DELIM"
			cat "$template"
			printf '%s\n' "$PA_DELIM"
			printf '}\n\n'
		fi

		printf '# ============================================================\n'
		printf '# Ponto de entrada\n'
		printf '# ============================================================\n\n'
		printf 'main "$@"\n'
	} >"$destino"

	# A data de build só existe no arquivo gerado. No fonte a
	# variável fica como "desenvolvimento", que é o sinal de que
	# aquilo não é artefato publicado.
	sed -i "s/^PA_BUILD=\"desenvolvimento\"$/PA_BUILD=\"${build}\"/" "$destino"

	grep -q "^PA_BUILD=\"${build}\"$" "$destino" ||
		erro "${alvo}: não consegui injetar a data de build"
}

# ------------------------------------------------------------
# Validação do artefato
# ------------------------------------------------------------

# validar <alvo> <arquivo>
validar() {
	local alvo="$1"
	local arquivo="$2"

	local template="${PA_TEMPLATE[$alvo]}"

	bash -n "$arquivo" || erro "${alvo}: não passa em bash -n"

	if command -v shellcheck >/dev/null 2>&1; then
		shellcheck --format=gcc "$arquivo" ||
			erro "${alvo}: não passa em shellcheck"
		info "${alvo}: shellcheck sem warnings"
	else
		info "${alvo}: shellcheck não encontrado; validação parcial"
	fi

	# Prova de que o artefato roda: --version não toca em nada da
	# máquina e exercita o parse de flags e a concatenação.
	bash "$arquivo" --version >/dev/null ||
		erro "${alvo}: falhou em --version"

	[[ -n "$template" ]] || return 0

	# Prova de que o template embutido saiu íntegro, comparando byte
	# a byte com o original.
	#
	# A extração é feita lendo o texto, e não dando `source` no
	# arquivo: o dist termina com a chamada do main, então
	# carregá-lo rodaria o instalador de verdade na máquina de quem
	# está compilando.
	local extraido
	extraido="$(mktemp)"

	awk -v d="$PA_DELIM" '
		index($0, d) && !dentro { dentro = 1; next }
		dentro && $0 == d       { exit }
		dentro                  { print }
	' "$arquivo" >"$extraido"

	if ! diff -q "$template" "$extraido" >/dev/null 2>&1; then
		rm -f "$extraido"
		erro "${alvo}: o template embutido difere de ${template}"
	fi

	info "${alvo}: template idêntico ao original ($(wc -l <"$extraido") linhas)"
	rm -f "$extraido"
}

# ------------------------------------------------------------
# Corpo, sem o cabeçalho
#
# Serve para comparar duas builds ignorando a data. Sem isso, todo
# build produziria um diff mesmo sem mudança no fonte, e o
# `git status` viveria sujo.
# ------------------------------------------------------------

corpo() {
	local arquivo="$1"

	[[ -f "$arquivo" ]] || return 0

	sed -e '/^# Build:/d' -e '/^PA_BUILD=/d' "$arquivo"
}

# ------------------------------------------------------------
# main
# ------------------------------------------------------------

modo="${1:-gerar}"

case "$modo" in
	gerar | --check) ;;
	*) erro "modo desconhecido: ${modo} (use --check ou nada)" ;;
esac

build="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
defasados=0

for alvo in "${PA_ALVOS[@]}"; do
	saida="${PA_SAIDA[$alvo]}"

	temporario="$(mktemp)"

	gerar "$alvo" "$temporario" "$build"
	validar "$alvo" "$temporario"

	if [[ "$modo" == "--check" ]]; then
		if [[ ! -f "$saida" ]]; then
			info "${alvo}: ${saida} não existe"
			defasados=1
		elif [[ "$(corpo "$temporario")" != "$(corpo "$saida")" ]]; then
			info "${alvo}: ${saida} está defasado"
			defasados=1
		else
			info "${alvo}: ${saida} está em dia"
		fi

		rm -f "$temporario"
		continue
	fi

	mkdir -p "$(dirname "$saida")"

	# Se só a data mudaria, não reescreve. Regenerar o dist faz
	# parte do commit, e um diff que muda apenas o timestamp faz o
	# revisor procurar uma alteração que não existe.
	if [[ "$(corpo "$temporario")" == "$(corpo "$saida")" ]]; then
		info "${alvo}: já está em dia; nada reescrito"
		rm -f "$temporario"
		continue
	fi

	cp "$temporario" "$saida"
	chmod +x "$saida"
	rm -f "$temporario"

	info "${alvo}: gerado ${saida}"
	info "  versão: $(ler_var PA_VERSAO "$(orquestrador_de "$alvo")")"
	info "  build:  ${build}"
	info "  linhas: $(wc -l <"$saida")"
done

if [[ "$modo" == "--check" ]] && [[ "$defasados" -eq 1 ]]; then
	erro "dist/ está defasado em relação a lib/; rode ./build.sh"
fi
