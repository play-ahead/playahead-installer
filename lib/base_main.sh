#!/usr/bin/env bash
# shellcheck shell=bash
#
# ============================================================
# lib/base_main.sh
# Orquestrador do instalador de base.
#
# Depende de todas as libs de base. No dist/base.sh gerado pelo
# build.sh, este é o último trecho, e a chamada a `main "$@"` fica
# no rodapé do arquivo.
#
# A base entrega a infraestrutura que os instaladores de
# ferramenta compartilham: swap, Docker, Compose, a rede do proxy,
# o Traefik e o Portainer.
#
# O Portainer está no fluxo normal, e não atrás de flag. Ficar
# atrás de flag era resquício do desenho em que um instalador
# chamava o outro: ali o Portainer podia subir no meio de uma
# instalação de Mautic, que leva minutos, e o prazo de criação do
# administrador expirava sozinho. Com os instaladores separados a
# base sempre roda antes das ferramentas e termina com a pessoa na
# frente do terminal, então o prazo deixou de ser problema e a
# flag deixou de ter motivo.
#
# Além disso, o menu anuncia a opção 1 como "Base (Docker, Traefik
# e Portainer)". Prometer na lista e entregar atrás de uma flag
# que a lista não menciona foi exatamente o que confundiu no teste
# de 2026-09-30.
#
# Quem não quer o Portainer usa --sem-portainer, ou aperta Enter
# na pergunta do subdomínio.
#
# Nenhum instalador de ferramenta chama este script. Faltando a
# base, a ferramenta diz o que falta, mostra o comando e encerra.
# Decisão de projeto: um script que a pessoa acabou de ler não vai
# buscar e executar outro por conta própria.
# ============================================================

# ------------------------------------------------------------
# Versão
#
# Independente da versão dos instaladores de ferramenta: cada um
# versiona por conta própria, e a tag leva o prefixo do nome.
# ------------------------------------------------------------

PA_VERSAO="0.1.0"
PA_BUILD="desenvolvimento"
PA_FONTE="https://github.com/play-ahead/playahead-installer"
PA_FERRAMENTA="Base: Docker, Traefik e Portainer"

# ------------------------------------------------------------
# Respostas e flags
# ------------------------------------------------------------

PA_EMAIL_ACME=""
# Portainer ligado por padrão, porque está no fluxo normal.
# --sem-portainer desliga, e Enter na pergunta também.
PA_PORTAINER=1
PA_PORTAINER_DOMINIO=""
PA_SKIP_DNS=0
PA_NO_SWAP=0
PA_NAO_INTERATIVO=0

# ------------------------------------------------------------
# Ajuda e versão
# ------------------------------------------------------------

main_versao() {
	printf 'Play Ahead Installer - %s\n' "$PA_FERRAMENTA"
	printf 'Versão: %s\n' "$PA_VERSAO"
	printf 'Build:  %s\n' "$PA_BUILD"
	printf 'Fonte:  %s\n' "$PA_FONTE"
}

main_ajuda() {
	cat <<'AJUDA'
Play Ahead Installer - Base

Instala a infraestrutura que os instaladores de ferramenta da Play
Ahead compartilham: swap, Docker, Docker Compose, a rede do proxy e
o Traefik com certificado SSL automático, e o Portainer.

Rode isto uma vez por VPS. Depois, cada ferramenta (Mautic 7,
Chatwoot, Typebot) tem o seu próprio instalador e reaproveita esta
base em vez de recriá-la.

USO
    sudo bash base.sh [opções]

OPÇÕES
    --acme-email=EMAIL           e-mail usado no Let's Encrypt
    --portainer-domain=DOMINIO   subdomínio do Portainer
    --sem-portainer              não instala o Portainer
    --skip-dns-check             pula a validação de DNS
    --no-swap                    não cria arquivo de swap
    --yes                        não interativo, sem nenhuma pergunta
    --help                       mostra esta ajuda
    --version                    mostra a versão e a data do build

EXEMPLOS
    sudo bash base.sh

    sudo bash base.sh --sem-portainer

    sudo bash base.sh --yes \
        --acme-email=voce@exemplo.com.br \
        --portainer-domain=painel.exemplo.com.br

DOCUMENTAÇÃO
    https://github.com/play-ahead/playahead-installer
AJUDA
}

# ------------------------------------------------------------
# Parse das flags
# ------------------------------------------------------------

main_parse_flags() {
	local arg

	for arg in "$@"; do
		case "$arg" in
			--acme-email=*) PA_EMAIL_ACME="${arg#*=}" ;;
			--portainer-domain=*)
				PA_PORTAINER_DOMINIO="${arg#*=}"
				PA_PORTAINER=1
				;;
			--sem-portainer) PA_PORTAINER=0 ;;
			--skip-dns-check) PA_SKIP_DNS=1 ;;
			--no-swap) PA_NO_SWAP=1 ;;
			--yes | -y) PA_NAO_INTERATIVO=1 ;;
			--help | -h)
				main_ajuda
				exit 0
				;;
			--version | -V)
				main_versao
				exit 0
				;;
			*)
				printf 'Opção desconhecida: %s\n\n' "$arg" >&2
				main_ajuda >&2
				exit 1
				;;
		esac
	done

	return 0
}

# ------------------------------------------------------------
# Detecção e checagens dependentes do estado
# ------------------------------------------------------------

base_detectar() {
	ui_secao "Descobrindo a situação desta máquina"

	cenario_classificar

	if [[ "$PA_TEM_TRAEFIK" -eq 1 ]]; then
		ui_ok "Já existe um proxy Traefik nesta máquina"
		ui_detalhe "Ele será reaproveitado; nada da configuração dele será tocado."
		traefik_mostrar_deteccao
		return 0
	fi

	# Sem proxy, as portas 80 e 443 precisam estar livres. Quem as
	# ocupa é servidor web instalado direto no sistema, e o
	# instalador não desliga serviço de ninguém.
	#
	# É aqui que moram as duas linhas da tabela de estados que
	# abortam, e é por isso que a checagem de portas não vive em
	# cenario.sh: ela só importa para quem vai subir um proxy.
	portas_livres "$([[ "$PA_TEM_DOCKER" -eq 0 ]] && printf 1 || printf 0)"

	if [[ "$PA_TEM_DOCKER" -eq 1 ]]; then
		ui_ok "Docker presente, sem proxy"
		ui_detalhe "Docker será reaproveitado; Traefik será instalado."
	else
		ui_ok "Máquina limpa"
		ui_detalhe "Docker, Compose e Traefik serão instalados."
	fi
}

# ------------------------------------------------------------
# Perguntas
#
# Todas antes de qualquer alteração na máquina, como o resto do
# projeto. A base é dona da própria conversa quando roda sozinha,
# e com --yes não pergunta nada.
# ------------------------------------------------------------

base_perguntar() {
	local pergunta_acme=0
	local pergunta_portainer=0

	# O e-mail do ACME só é necessário quando este script vai
	# instalar o Traefik. Havendo proxy, quem emite certificado é
	# ele, com o e-mail que já tem.
	[[ "$PA_TEM_TRAEFIK" -eq 0 ]] && [[ -z "$PA_EMAIL_ACME" ]] &&
		pergunta_acme=1
	[[ "$PA_PORTAINER" -eq 1 ]] && [[ -z "$PA_PORTAINER_DOMINIO" ]] &&
		pergunta_portainer=1

	# O Portainer entrou no fluxo normal, então no modo automático
	# o subdomínio passou a ser dado que falta, e não opção que
	# ninguém pediu. A regra do --yes é falhar dizendo o que falta,
	# em vez de escolher em silêncio: instalar sem DNS deixaria um
	# painel inacessível de pé, e pular calado contraria o que o
	# menu anuncia na opção 1.
	if [[ "$pergunta_portainer" -eq 1 ]] && ! ui_interativo; then
		ui_fatal \
			"Falta o subdomínio do Portainer." \
			"No modo automático, escolha uma das duas:" \
			"" \
			"    --portainer-domain=painel.exemplo.com.br" \
			"    --sem-portainer"
	fi

	if [[ "$pergunta_acme" -eq 0 ]] && [[ "$pergunta_portainer" -eq 0 ]]; then
		return 0
	fi

	ui_secao "Algumas perguntas antes de começar"
	ui_info "Depois daqui a instalação corre sozinha até o fim."

	if [[ "$pergunta_acme" -eq 1 ]]; then
		ui_vazio
		ui_info "O Let's Encrypt pede um e-mail para avisar sobre a"
		ui_info "renovação do certificado. Ele vai para a Let's Encrypt,"
		ui_info "não para a Play Ahead."
		ui_perguntar PA_EMAIL_ACME \
			"E-mail para o certificado SSL" \
			"" checks_validar_email
	fi

	if [[ "$pergunta_portainer" -eq 1 ]]; then
		ui_vazio
		ui_info "O Portainer é um painel para ver e mexer nos containers"
		ui_info "desta VPS pelo navegador. Ele precisa de um subdomínio"
		ui_info "próprio, com DNS apontando para cá."
		ui_detalhe "Aperte Enter para não instalar."

		if ! ui_perguntar_opcional PA_PORTAINER_DOMINIO \
			"Subdomínio do Portainer (ex: painel.suaempresa.com.br)" \
			checks_validar_dominio; then

			PA_PORTAINER=0
			ui_info "Portainer não será instalado."
		fi
	fi
}

# ------------------------------------------------------------
# Validação
# ------------------------------------------------------------

base_validar() {
	[[ "$PA_PORTAINER" -eq 1 ]] || return 0
	[[ "$PA_SKIP_DNS" -eq 0 ]] || return 0

	ui_secao "Conferindo o DNS do Portainer"
	checks_ip_publico || true

	# Avisa em vez de abortar: o Portainer é opcional, e o resto da
	# base não depende do DNS dele.
	if [[ -z "$PA_IP_PUBLICO" ]]; then
		ui_aviso "Não consegui descobrir o IP desta máquina; seguindo."
		return 0
	fi

	local resolvidos=()
	mapfile -t resolvidos < <(
		getent ahostsv4 "$PA_PORTAINER_DOMINIO" 2>/dev/null |
			awk '{print $1}' | sort -u
	)

	if [[ "${#resolvidos[@]}" -eq 0 ]]; then
		ui_aviso "${PA_PORTAINER_DOMINIO} ainda não resolve para nenhum IP."
		ui_detalhe "O Portainer vai subir, mas o domínio só abre depois de"
		ui_detalhe "o DNS apontar para ${PA_IP_PUBLICO}."
		return 0
	fi

	if [[ " ${resolvidos[*]} " == *" ${PA_IP_PUBLICO} "* ]]; then
		ui_ok "DNS de ${PA_PORTAINER_DOMINIO} aponta para esta VPS"
		return 0
	fi

	if checks_ip_em_cdn "${resolvidos[0]}"; then
		ui_aviso "${PA_PORTAINER_DOMINIO} está atrás de CDN; seguindo."
		return 0
	fi

	ui_aviso "${PA_PORTAINER_DOMINIO} aponta para outro servidor."
	ui_detalhe "resolve para: ${resolvidos[*]}"
	ui_detalhe "esta VPS é:   ${PA_IP_PUBLICO}"
	ui_detalhe "O Portainer vai subir, mas o domínio não vai abrir."
}

# ------------------------------------------------------------
# Confirmação
# ------------------------------------------------------------

# base_confirmar
#
# Último ponto antes de escrever qualquer coisa. Diz em palavras o
# que vai ser feito com cada peça, e não só o que foi respondido:
# "reaproveitar" e "instalar" são decisões que a pessoa precisa
# poder conferir antes de o script mexer na máquina.
base_confirmar() {
	local ram acao_swap
	ram="$(sistema_ram_mb)"

	if [[ "$PA_NO_SWAP" -eq 1 ]]; then
		acao_swap="não mexer, por --no-swap"
	elif sistema_tem_swap; then
		acao_swap="já existe, manter"
	elif [[ "$ram" -lt "$PA_RAM_SWAP_MB" ]]; then
		acao_swap="criar 2 GB (RAM de ${ram} MB)"
	else
		acao_swap="dispensado (RAM de ${ram} MB)"
	fi

	# Usa os sinalizadores que cenario_classificar preencheu, e não
	# uma pergunta nova ao Docker: o resumo tem de dizer o que o
	# resto do fluxo decidiu, não fazer a própria leitura.
	local acao_docker="instalar"
	[[ "$PA_TEM_DOCKER" -eq 1 ]] && [[ "$PA_TEM_COMPOSE" -eq 1 ]] &&
		acao_docker="reaproveitar $(docker_versao)"

	local acao_traefik="instalar ${PA_TRAEFIK_VERSAO}"
	[[ "$PA_TEM_TRAEFIK" -eq 1 ]] &&
		acao_traefik="reaproveitar o que já está no ar"

	# Cada linha leva a origem do valor. Swap, Docker e Traefik
	# saem de leitura da máquina; e-mail do SSL e subdomínio do
	# Portainer saem da pessoa, e são os dois que um erro de
	# digitação estraga em silêncio: e-mail errado no ACME e
	# subdomínio errado no Portainer só aparecem depois, quando o
	# certificado falha.
	local -a itens=(
		"Swap" "$acao_swap" detectado
		"Docker e Compose" "$acao_docker" detectado
		"Traefik" "$acao_traefik" detectado
	)

	[[ "$PA_TEM_TRAEFIK" -eq 0 ]] &&
		itens+=("E-mail do SSL" "$PA_EMAIL_ACME" informado)

	if [[ "$PA_PORTAINER" -eq 1 ]]; then
		itens+=("Portainer" "https://${PA_PORTAINER_DOMINIO}" informado)
	else
		itens+=("Portainer" "não instalar" informado)
	fi

	ui_resumo "Confira antes de começar" "${itens[@]}"
	ui_confirmar_resumo
}

# ------------------------------------------------------------
# Instalação
# ------------------------------------------------------------

base_instalar() {
	ui_secao "Preparando a máquina"

	sistema_criar_swap "$PA_NO_SWAP"
	docker_garantir

	if [[ "$PA_TEM_TRAEFIK" -eq 1 ]]; then
		ui_ok "Traefik já existente mantido como está"
		return 0
	fi

	traefik_instalar "$PA_EMAIL_ACME"
}

# ------------------------------------------------------------
# Bloco final
# ------------------------------------------------------------

base_bloco_final() {
	ui_vazio
	ui_secao "Base pronta"

	ui_info "A infraestrutura compartilhada está no ar:"
	ui_vazio
	ui_info "Docker:       $(docker_versao)"
	ui_info "Compose:      $(docker_compose_versao)"
	ui_info "Rede do proxy: ${PA_TRAEFIK_NETWORK:-${PA_TRAEFIK_REDE}}"
	ui_info "Entrypoint:   ${PA_TRAEFIK_ENTRYPOINT:-websecure}"
	ui_info "Certresolver: ${PA_TRAEFIK_CERTRESOLVER:-<nenhum>}"

	if [[ -n "$PA_SWAP_CRIADO" ]]; then
		ui_vazio
		ui_info "Um arquivo de swap de 2 GB foi criado em ${PA_SWAP_CRIADO}"
		ui_info "porque esta máquina tem pouca memória."
	fi

	portainer_bloco_final

	ui_vazio
	ui_info "Agora instale as ferramentas que quiser. Cada uma tem o"
	ui_info "seu próprio instalador e reaproveita esta base:"
	ui_detalhe "Mautic 7:  https://get.playahead.com.br/mautic7"
	ui_vazio
	ui_separador
	ui_info "Quer receber avisos de novas versões, correções e conteúdos"
	ui_info "da Play Ahead sobre automação de marketing?"
	ui_detalhe "https://playahead.com.br/avisos"
	ui_separador
	ui_vazio
}

# ------------------------------------------------------------
# main
# ------------------------------------------------------------

main() {
	main_parse_flags "$@"

	ui_init "$PA_NAO_INTERATIVO"
	ui_cabecalho

	checks_sistema
	base_detectar
	base_perguntar
	base_validar
	base_confirmar
	base_instalar

	if [[ "$PA_PORTAINER" -eq 1 ]]; then
		portainer_instalar "$PA_PORTAINER_DOMINIO" || true
	fi

	base_bloco_final
}
