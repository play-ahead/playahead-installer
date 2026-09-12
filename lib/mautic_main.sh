#!/usr/bin/env bash
# shellcheck shell=bash
#
# ============================================================
# lib/mautic_main.sh
# Orquestrador do instalador do Mautic 7.
#
# Depende das libs compartilhadas e de lib/mautic.sh. No
# dist/mautic7.sh gerado pelo build.sh, este é o último trecho, e
# a chamada a `main "$@"` fica no rodapé do arquivo.
#
# Este instalador **não instala a base**. Faltando Docker, Compose
# ou Traefik, ele diz o que falta, mostra o comando do instalador
# de base e encerra sem tocar em nada. A pessoa roda a base, vê o
# que aconteceu, e volta.
#
# Decisão de projeto por trás disso: um script que a pessoa acabou
# de ler com `less` não vai buscar e executar outro por conta
# própria. E a base num lugar só é o que faz os próximos
# instaladores herdarem infraestrutura em vez de recriá-la.
#
# O princípio que organiza o resto continua: **todas as perguntas
# acontecem antes de qualquer alteração na máquina.**
# ============================================================

# ------------------------------------------------------------
# Versão
#
# O build.sh substitui estes dois valores no dist/mautic7.sh.
# Rodando direto do repositório eles ficam como estão, o que é
# sinal de que não é um artefato publicado.
# ------------------------------------------------------------

PA_VERSAO="0.1.0"
PA_BUILD="desenvolvimento"
PA_FONTE="https://github.com/play-ahead/playahead-installer"

# Qual ferramenta este instalador instala.
#
# Fica aqui, e não em lib/ui.sh, porque ui.sh é genérico e vai
# ser reaproveitado pelos próximos instaladores do repositório.
# O build.sh lê esta variável para o cabeçalho do artefato.
PA_FERRAMENTA="Mautic 7 em Docker"

# ------------------------------------------------------------
# Respostas e flags
# ------------------------------------------------------------

PA_DOMINIO=""
PA_EMAIL_ADMIN=""
PA_WIZARD=0
PA_SKIP_DNS=0
PA_NAO_INTERATIVO=0
PA_SEM_CERTRESOLVER=0

# Idioma e fuso da instalação.
#
# O Mautic nasce em inglês e, por causa do contorno do fuso no
# instalador, com fuso UTC. Os dois são corrigidos depois da
# instalação, em mautic_regionalizar.
PA_IDIOMA="pt_BR"
PA_FUSO="America/Sao_Paulo"

# Caminho do template do compose. No dist/mautic7.sh o template
# vai embutido; aqui aponta para o repositório.
PA_TEMPLATE_MAUTIC="templates/docker-compose-mautic7-playahead.yml"

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
Play Ahead Installer - Mautic 7 em Docker

USO
    sudo bash mautic7.sh [opções]

Precisa da base instalada antes: Docker, Docker Compose e Traefik.
Faltando qualquer um, este script diz o que falta e mostra o
comando do instalador de base.

Sem nenhuma opção, o script pergunta o que precisa e instala.
Com as opções abaixo mais --yes, roda sem perguntar nada.

OPÇÕES
    --domain=DOMINIO             domínio do Mautic
    --admin-email=EMAIL          e-mail do administrador
    --traefik-network=NOME       força o nome da rede do Traefik
    --traefik-entrypoint=NOME    força o nome do entrypoint
    --traefik-certresolver=NOME  força o nome do certresolver
    --no-certresolver            para quem termina o SSL fora da VPS
    --idioma=CODIGO              idioma do painel (padrão pt_BR)
    --fuso=FUSO                  fuso horário (padrão America/Sao_Paulo)
    --wizard                     não conclui a instalação, deixa o
                                 assistente web do Mautic
    --skip-dns-check             pula a validação de DNS
    --yes                        não interativo, sem nenhuma pergunta
    --help                       mostra esta ajuda
    --version                    mostra a versão e a data do build

EXEMPLOS
    sudo bash mautic7.sh

    sudo bash mautic7.sh --domain=mautic.exemplo.com.br \
        --acme-email=voce@exemplo.com.br --yes

DOCUMENTAÇÃO
    https://github.com/play-ahead/playahead-installer
AJUDA
}

# ------------------------------------------------------------
# Parse das flags
#
# Etapa 0. Roda antes de tudo e não toca em nada da máquina.
# --help e --version saem aqui mesmo.
# ------------------------------------------------------------

main_parse_flags() {
	local arg

	for arg in "$@"; do
		case "$arg" in
			--domain=*) PA_DOMINIO="${arg#*=}" ;;
			--admin-email=*) PA_EMAIL_ADMIN="${arg#*=}" ;;
			--traefik-network=*) PA_TRAEFIK_NETWORK="${arg#*=}" ;;
			--traefik-entrypoint=*) PA_TRAEFIK_ENTRYPOINT="${arg#*=}" ;;
			--traefik-certresolver=*) PA_TRAEFIK_CERTRESOLVER="${arg#*=}" ;;
			--idioma=*) PA_IDIOMA="${arg#*=}" ;;
			--fuso=*) PA_FUSO="${arg#*=}" ;;
			--no-certresolver) PA_SEM_CERTRESOLVER=1 ;;
			--wizard) PA_WIZARD=1 ;;
			--skip-dns-check) PA_SKIP_DNS=1 ;;
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

	# Origem das flags, para a tabela de confirmação do cenário 2
	# não dizer "não encontrado" sobre algo que a pessoa informou.
	#
	# As três são lidas por traefik_mostrar_deteccao, em outro
	# arquivo; o shellcheck não enxerga uso entre arquivos.
	# shellcheck disable=SC2034
	[[ -n "$PA_TRAEFIK_NETWORK" ]] &&
		PA_TRAEFIK_NETWORK_ORIGEM="informado em --traefik-network"
	# shellcheck disable=SC2034
	[[ -n "$PA_TRAEFIK_ENTRYPOINT" ]] &&
		PA_TRAEFIK_ENTRYPOINT_ORIGEM="informado em --traefik-entrypoint"
	# shellcheck disable=SC2034
	[[ -n "$PA_TRAEFIK_CERTRESOLVER" ]] &&
		PA_TRAEFIK_CERTRESOLVER_ORIGEM="informado em --traefik-certresolver"

	return 0
}

# ------------------------------------------------------------
# Etapa 2 — a base está pronta?
# ------------------------------------------------------------

# mautic_checar_base
#
# Para este instalador não existem cinco cenários, existem dois: a
# base está pronta, ou falta rodar a base.
#
# Faltando, ele **não instala nada e não busca nada na rede**. Diz
# o que falta, mostra o comando pronto na tela e encerra com 1. A
# pessoa instala a base, vê o resultado, e roda isto de novo.
mautic_checar_base() {
	ui_secao "Conferindo a base"

	cenario_classificar

	if cenario_base_completa; then
		ui_ok "Base pronta: Docker $(docker_versao), Compose $(docker_compose_versao)"
		ui_detalhe "Traefik encontrado em ${PA_TRAEFIK_CONTAINER}."
		return 0
	fi

	local faltando
	faltando="$(cenario_faltando)"

	ui_vazio
	ui_erro "Falta a base desta VPS: ${faltando}."
	ui_vazio
	ui_info "O Mautic precisa de Docker, Docker Compose e um proxy"
	ui_info "Traefik já no ar. Quem instala isso é o instalador de base,"
	ui_info "que roda uma vez por VPS e serve a todas as ferramentas."
	ui_vazio
	ui_info "Baixe, leia e rode a base:"
	ui_vazio
	ui_linha "    curl -sL https://get.playahead.com.br/base -o base.sh"
	ui_linha "    less base.sh"
	ui_linha "    sudo bash base.sh"
	ui_vazio
	ui_info "Terminada a base, rode este instalador de novo:"
	ui_vazio
	ui_linha "    sudo bash ${0}"
	ui_vazio
	ui_info "Nada foi alterado nesta máquina."
	ui_vazio

	exit 1
}

# ------------------------------------------------------------
# Etapa 4 — instalação anterior
# ------------------------------------------------------------

main_checar_instalacao_anterior() {
	local estado
	estado="$(mautic_detectar_estado)"

	case "$estado" in
		parcial) mautic_abortar_parcial ;;
		coerente)
			ui_secao "Instalação encontrada"
			ui_ok "Já existe uma instalação completa em ${PA_MAUTIC_DIR}"
			ui_vazio
			ui_info "Nada será reinstalado e nada será apagado."
			ui_vazio
			ui_info "Para reiniciar a stack:"
			ui_detalhe "cd ${PA_MAUTIC_DIR} && docker compose up -d"
			ui_vazio
			ui_info "As credenciais estão em:"
			ui_detalhe "$PA_MAUTIC_CREDENCIAIS"
			ui_vazio
			exit 0
			;;
	esac
}

# ------------------------------------------------------------
# Etapa 5 — bloco único de perguntas
# ------------------------------------------------------------

main_perguntar() {
	ui_secao "Algumas perguntas antes de começar"
	ui_info "Depois daqui a instalação corre sozinha até o fim."
	ui_vazio

	# 1. domínio
	if [[ -z "$PA_DOMINIO" ]]; then
		ui_perguntar PA_DOMINIO \
			"Domínio do Mautic (ex: mautic.suaempresa.com.br)" \
			"" checks_validar_dominio
	fi

	# 2. e-mail do admin
	#
	# O e-mail do Let's Encrypt não é perguntado aqui: quem emite
	# certificado é o Traefik, e quem configura o Traefik é a base.
	if [[ -z "$PA_EMAIL_ADMIN" ]]; then
		local sugestao="admin@${PA_DOMINIO}"
		ui_vazio
		ui_perguntar PA_EMAIL_ADMIN 			"E-mail para entrar no Mautic" 			"$sugestao" checks_validar_email
	fi

	# 3. confirmação dos valores do Traefik
	#
	# Sempre, e não mais só no cenário 2: daqui em diante o Traefik é
	# sempre de outro script, mesmo quando foi a nossa base que o
	# instalou. Um caminho só, e a tela diz de onde veio cada valor.
	main_confirmar_traefik
}

# main_confirmar_traefik
#
# Mostra o que foi detectado, com a origem de cada valor, e pede
# confirmação. Cravar os nomes padrão faz o container subir, o
# Mautic funcionar e o domínio devolver 404 sem mensagem nenhuma.
main_confirmar_traefik() {
	if [[ "$PA_SEM_CERTRESOLVER" -eq 1 ]]; then
		PA_TRAEFIK_CERTRESOLVER=""
		# Lida por traefik_mostrar_deteccao, em outro arquivo.
		# shellcheck disable=SC2034
		PA_TRAEFIK_CERTRESOLVER_ORIGEM="omitido por --no-certresolver"
	fi

	traefik_mostrar_deteccao

	if ui_confirmar "Os valores acima estão corretos?" 1; then
		return 0
	fi

	ui_vazio
	ui_info "Informe os valores corretos. Enter mantém o detectado."

	ui_perguntar PA_TRAEFIK_NETWORK \
		"Rede do Traefik" "${PA_TRAEFIK_NETWORK:-traefik_public}"
	ui_perguntar PA_TRAEFIK_ENTRYPOINT \
		"Entrypoint HTTPS" "${PA_TRAEFIK_ENTRYPOINT:-websecure}"

	if ui_confirmar "Este Traefik emite certificado (Let's Encrypt)?" 1; then
		ui_perguntar PA_TRAEFIK_CERTRESOLVER \
			"Nome do certresolver" "${PA_TRAEFIK_CERTRESOLVER:-letsencrypt}"
	else
		PA_TRAEFIK_CERTRESOLVER=""
		ui_detalhe "O label de certresolver será omitido."
	fi
}

# ------------------------------------------------------------
# Etapa 6 — validação
# ------------------------------------------------------------

main_validar() {
	ui_secao "Conferindo o domínio"

	if [[ "$PA_SKIP_DNS" -eq 1 ]]; then
		ui_aviso "Validação de DNS pulada por --skip-dns-check."
		return 0
	fi

	checks_ip_publico || true
	checks_dns "$PA_DOMINIO"
}

# ------------------------------------------------------------
# Etapas 7 e 8 — instalação
# ------------------------------------------------------------

main_instalar() {
	ui_secao "Instalando o Mautic"

	mautic_gravar_compose "$PA_TEMPLATE_MAUTIC"
	mautic_gerar_env "$PA_DOMINIO"

	mautic_subir_banco
	mautic_subir_web

	if [[ "$PA_WIZARD" -eq 1 ]]; then
		ui_ok "Instalação por linha de comando pulada por --wizard"
		ui_detalhe "Conclua pelo navegador; as credenciais do banco estão"
		ui_detalhe "no bloco final e em ${PA_MAUTIC_CREDENCIAIS}."

		# Com --wizard o pacote de idioma entra, mas a configuração
		# não: quem completa o assistente reescreve o local.php no
		# fim, e gravar idioma e fuso antes disso seria trabalho
		# jogado fora. Com o pacote no lugar, o idioma já aparece
		# como opção na tela do assistente.
		mautic_instalar_idioma "$PA_IDIOMA" || true
		ui_detalhe "Escolha o idioma e o fuso no próprio assistente."
	else
		mautic_instalar "$PA_DOMINIO" "$PA_EMAIL_ADMIN"

		# Só faz sentido depois de o instalador ter criado o
		# local.php com as chaves. Numa instalação já existente,
		# respeitar o que a pessoa configurou.
		if [[ "$PA_MAUTIC_JA_INSTALADO" -eq 0 ]]; then
			mautic_regionalizar "$PA_IDIOMA" "$PA_FUSO"
		fi
	fi

	mautic_subir_resto
	mautic_gravar_credenciais "$PA_DOMINIO" "$PA_EMAIL_ADMIN"
}

# ------------------------------------------------------------
# Etapa 11 — bloco final
# ------------------------------------------------------------

main_bloco_final() {
	ui_vazio
	ui_secao "Pronto"

	ui_info "Mautic instalado e no ar."
	ui_vazio
	ui_info "URL:      https://${PA_DOMINIO}"

	if [[ "$PA_WIZARD" -eq 1 ]]; then
		ui_vazio
		ui_info "Você usou --wizard, então falta concluir a instalação"
		ui_info "pelo navegador. Use estes dados na tela de banco:"
		ui_detalhe "host:    mariadb"
		ui_detalhe "porta:   3306"
		ui_detalhe "base:    mautic"
		ui_detalhe "usuário: mautic"
		ui_detalhe "senha:   ${PA_MAUTIC_SENHA_BANCO}"
	elif [[ "$PA_MAUTIC_JA_INSTALADO" -eq 1 ]]; then
		ui_info "E-mail:   ${PA_EMAIL_ADMIN}"
		ui_info "Senha:    a definida na instalação anterior"
	else
		ui_info "E-mail:   ${PA_EMAIL_ADMIN}"
		ui_info "Senha:    ${PA_MAUTIC_SENHA_ADMIN}"
	fi

	ui_vazio
	ui_info "Credenciais salvas em:"
	ui_detalhe "$PA_MAUTIC_CREDENCIAIS"
	ui_info "Guarde num gerenciador de senhas. O arquivo não é apagado."
	ui_vazio
	ui_info "Arquivos da instalação:"
	ui_detalhe "$PA_MAUTIC_DIR"

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

	# Encerra aqui, sem tocar em nada, se a base não estiver pronta.
	mautic_checar_base

	# Antes de qualquer pergunta, para não fazer a pessoa digitar o
	# domínio à toa quando o script vai apenas reconciliar e sair.
	main_checar_instalacao_anterior

	main_perguntar
	main_validar
	main_instalar

	# Não aborta: o Mautic está no ar de qualquer jeito, e a regra do
	# projeto é não derrubar nada quando algo dá errado.
	mautic_verificar_roteamento "$PA_DOMINIO" || true

	main_bloco_final
}
