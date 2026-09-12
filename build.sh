#!/usr/bin/env bash
# shellcheck shell=bash
#
# ============================================================
# build.sh
# Gera dist/install.sh a partir de lib/*.sh.
#
# O código-fonte é modular, mas o que é publicado é um arquivo
# único: um script baixado sozinho por curl não consegue dar
# source em arquivos que não existem na VPS.
#
# USO
#     ./build.sh            gera dist/install.sh
#     ./build.sh --check    só verifica se o dist está em dia
#                           (para CI e para o hook de commit)
# ============================================================

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

# ------------------------------------------------------------
# Configuração
# ------------------------------------------------------------

# A ORDEM IMPORTA. Não é alfabética: é a ordem de dependência.
# ui primeiro porque todo mundo usa ui_fatal; main por último
# porque é quem chama todos os outros.
PA_LIBS=(
	ui
	checks
	sistema
	docker
	traefik
	portainer
	mautic
	main
)

PA_SAIDA="dist/install.sh"
PA_TEMPLATE="templates/docker-compose-mautic7-playahead.yml"
PA_FONTE="https://github.com/playahead/script-mautic-7"

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
# Versão
#
# Fonte única: a variável PA_VERSAO em lib/main.sh. O build só
# propaga, nunca decide. Ter a versão em dois lugares é como não
# ter versão nenhuma.
# ------------------------------------------------------------

ler_versao() {
	local versao
	versao="$(
		awk -F'"' '/^PA_VERSAO=/ {print $2; exit}' lib/main.sh
	)"

	[[ -n "$versao" ]] || erro "não achei PA_VERSAO em lib/main.sh"

	printf '%s\n' "$versao"
}

# ------------------------------------------------------------
# Geração
# ------------------------------------------------------------

# gerar <arquivo_destino> <versao> <build>
gerar() {
	local destino="$1"
	local versao="$2"
	local build="$3"

	local lib
	for lib in "${PA_LIBS[@]}"; do
		[[ -f "lib/${lib}.sh" ]] || erro "falta lib/${lib}.sh"
	done

	[[ -f "$PA_TEMPLATE" ]] || erro "falta $PA_TEMPLATE"

	if grep -qF "$PA_DELIM" "$PA_TEMPLATE"; then
		erro "o template contém o delimitador ${PA_DELIM}; troque o delimitador"
	fi

	{
		# O cabeçalho é o mesmo bloco de licença e aviso que o
		# script imprime na tela, mais os dados de versão. Quem
		# der `less install.sh` vê isso nas primeiras linhas, o
		# que é justamente o ponto do passo do `less`.
		cat <<CABECALHO
#!/usr/bin/env bash
# ============================================================
# PLAY AHEAD INSTALLER
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

		# As libs, na ordem de dependência. O shebang de cada uma
		# é removido: no meio de um arquivo ele seria só um
		# comentário, mas deixá-lo sugeriria que aquele trecho é
		# executável por conta própria.
		for lib in "${PA_LIBS[@]}"; do
			printf '# ============================================================\n'
			printf '# lib/%s.sh\n' "$lib"
			printf '# ============================================================\n\n'
			sed '1{/^#!/d}' "lib/${lib}.sh"
			printf '\n'
		done

		# O template do compose, embutido como heredoc citado.
		# Citado é obrigatório: o template está cheio de
		# ${MAUTIC_DOMAIN} e afins, que precisam chegar literais
		# ao arquivo final para o compose expandir depois.
		printf '# ============================================================\n'
		printf '# Template do compose, embutido pelo build.sh\n'
		printf '# ============================================================\n\n'
		printf 'mautic_template_embutido() {\n'
		printf "\tcat <<'%s'\n" "$PA_DELIM"
		cat "$PA_TEMPLATE"
		printf '%s\n' "$PA_DELIM"
		printf '}\n\n'

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
		erro "não consegui injetar a data de build; o formato de lib/main.sh mudou?"
}

# ------------------------------------------------------------
# Validação do artefato
# ------------------------------------------------------------

validar() {
	local arquivo="$1"

	bash -n "$arquivo" || erro "o arquivo gerado não passa em bash -n"

	if command -v shellcheck >/dev/null 2>&1; then
		shellcheck --format=gcc "$arquivo" ||
			erro "o arquivo gerado não passa em shellcheck"
		info "shellcheck: sem warnings"
	else
		info "shellcheck não encontrado; validação parcial"
	fi

	# Prova de que o artefato roda: --version não toca em nada da
	# máquina e exercita o parse de flags e a concatenação.
	bash "$arquivo" --version >/dev/null ||
		erro "o arquivo gerado falhou em --version"

	# Prova de que o template embutido saiu íntegro, comparando
	# byte a byte com o original.
	#
	# A extração é feita lendo o texto, e não dando `source` no
	# arquivo: o dist termina com `main "$@"`, então carregá-lo
	# rodaria o instalador de verdade na máquina de quem está
	# compilando.
	local extraido
	extraido="$(mktemp)"

	awk -v d="$PA_DELIM" '
		index($0, d) && !dentro { dentro = 1; next }
		dentro && $0 == d       { exit }
		dentro                  { print }
	' "$arquivo" >"$extraido"

	if ! diff -q "$PA_TEMPLATE" "$extraido" >/dev/null 2>&1; then
		rm -f "$extraido"
		erro "o template embutido difere de ${PA_TEMPLATE}"
	fi

	info "template embutido: idêntico ao original ($(wc -l <"$extraido") linhas)"
	rm -f "$extraido"
}

# ------------------------------------------------------------
# Corpo, sem o cabeçalho
#
# Serve para comparar duas builds ignorando a data. Sem isso,
# todo build produziria um diff mesmo sem mudança no fonte, e o
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

versao="$(ler_versao)"
build="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
temporario="$(mktemp)"
# shellcheck disable=SC2064
# Expandir agora é o que se quer: o caminho não muda mais.
trap "rm -f '$temporario'" EXIT

gerar "$temporario" "$versao" "$build"
validar "$temporario"

case "$modo" in
	--check)
		if [[ ! -f "$PA_SAIDA" ]]; then
			erro "$PA_SAIDA não existe; rode ./build.sh"
		fi

		if [[ "$(corpo "$temporario")" == "$(corpo "$PA_SAIDA")" ]]; then
			info "$PA_SAIDA está em dia com lib/"
			exit 0
		fi

		erro "$PA_SAIDA está defasado em relação a lib/; rode ./build.sh"
		;;

	gerar) ;;

	*)
		erro "modo desconhecido: ${modo} (use --check ou nada)"
		;;
esac

mkdir -p "$(dirname "$PA_SAIDA")"

# Se só a data mudaria, não reescreve. Regenerar o dist faz parte
# do commit, e um diff que muda apenas o timestamp faz o revisor
# procurar uma alteração que não existe.
if [[ "$(corpo "$temporario")" == "$(corpo "$PA_SAIDA")" ]]; then
	info "$PA_SAIDA já está em dia; nada reescrito"
	exit 0
fi

cp "$temporario" "$PA_SAIDA"
chmod +x "$PA_SAIDA"

info "gerado $PA_SAIDA"
info "  versão: ${versao}"
info "  build:  ${build}"
info "  linhas: $(wc -l <"$PA_SAIDA")"
info "  bytes:  $(wc -c <"$PA_SAIDA")"
