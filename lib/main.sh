#!/usr/bin/env bash
# shellcheck shell=bash
#
# ============================================================
# lib/main.sh
# Orquestrador: flags, ordem das etapas e bloco final.
#
# Depende de todas as outras libs. No dist/mautic7.sh gerado
# pelo build.sh, este é o último trecho, e a chamada a
# `main "$@"` fica no rodapé do arquivo.
#
# O princípio que organiza tudo: **todas as perguntas acontecem
# antes de qualquer alteração na máquina.** Depois que a
# instalação começa, ela vai até o fim sem input. As duas
# exceções são deliberadas e estão marcadas onde acontecem.
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
PA_EMAIL_ACME=""
PA_PORTAINER=0
PA_PORTAINER_DOMINIO=""
PA_WIZARD=0
PA_SKIP_DNS=0
PA_NO_SWAP=0
PA_NAO_INTERATIVO=0
PA_SEM_CERTRESOLVER=0

# Idioma e fuso da instalação.
#
# O Mautic nasce em inglês e, por causa do contorno do fuso no
# instalador, com fuso UTC. Os dois são corrigidos depois da
# instalação, em mautic_regionalizar.
PA_IDIOMA="pt_BR"
PA_FUSO="America/Sao_Paulo"

# Cenário detectado: 1, 1.5 ou 2.
PA_CENARIO=""

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

Sem nenhuma opção, o script pergunta o que precisa e instala.
Com as opções abaixo mais --yes, roda sem perguntar nada.

OPÇÕES
    --domain=DOMINIO             domínio do Mautic
    --admin-email=EMAIL          e-mail do administrador
    --acme-email=EMAIL           e-mail usado no Let's Encrypt
    --traefik-network=NOME       força o nome da rede do Traefik
    --traefik-entrypoint=NOME    força o nome do entrypoint
    --traefik-certresolver=NOME  força o nome do certresolver
    --no-certresolver            para quem termina o SSL fora da VPS
    --idioma=CODIGO              idioma do painel (padrão pt_BR)
    --fuso=FUSO                  fuso horário (padrão America/Sao_Paulo)
    --wizard                     não conclui a instalação, deixa o
                                 assistente web do Mautic
    --portainer                  instala o Portainer ao final
    --portainer-domain=DOMINIO   subdomínio do Portainer
    --skip-dns-check             pula a validação de DNS
    --no-swap                    não cria arquivo de swap
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
			--acme-email=*) PA_EMAIL_ACME="${arg#*=}" ;;
			--traefik-network=*) PA_TRAEFIK_NETWORK="${arg#*=}" ;;
			--traefik-entrypoint=*) PA_TRAEFIK_ENTRYPOINT="${arg#*=}" ;;
			--traefik-certresolver=*) PA_TRAEFIK_CERTRESOLVER="${arg#*=}" ;;
			--idioma=*) PA_IDIOMA="${arg#*=}" ;;
			--fuso=*) PA_FUSO="${arg#*=}" ;;
			--no-certresolver) PA_SEM_CERTRESOLVER=1 ;;
			--portainer) PA_PORTAINER=1 ;;
			--portainer-domain=*)
				PA_PORTAINER_DOMINIO="${arg#*=}"
				PA_PORTAINER=1
				;;
			--wizard) PA_WIZARD=1 ;;
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
# Etapa 2 — detecção do cenário
# ------------------------------------------------------------

# main_detectar_cenario
#
# A tabela de cinco estados do CLAUDE.md. Dois deles abortam:
# não são cenários, são máquinas em que não dá para instalar sem
# quebrar o que já está lá.
main_detectar_cenario() {
	ui_secao "Descobrindo a situação desta máquina"

	docker_checar_swarm

	local tem_docker=0 tem_traefik=0
	docker_presente && tem_docker=1

	if [[ "$tem_docker" -eq 1 ]] && traefik_detectar; then
		tem_traefik=1
	fi

	if [[ "$tem_traefik" -eq 1 ]]; then
		PA_CENARIO="2"
		ui_ok "Cenário 2: já existe um proxy Traefik nesta máquina"
		ui_detalhe "O Mautic vai ser anexado a ele, sem tocar na configuração."
		return 0
	fi

	# Sem Traefik, as portas 80 e 443 precisam estar livres. Se
	# alguém as ocupa, é servidor web instalado direto no sistema,
	# e o instalador não desliga serviço de ninguém.
	checks_portas_livres "$([[ "$tem_docker" -eq 0 ]] && printf 1 || printf 0)"

	if [[ "$tem_docker" -eq 1 ]]; then
		PA_CENARIO="1.5"
		ui_ok "Cenário 1.5: Docker presente, sem proxy"
		ui_detalhe "Docker será reaproveitado; Traefik e Mautic serão instalados."
	else
		PA_CENARIO="1"
		ui_ok "Cenário 1: máquina limpa"
		ui_detalhe "Docker, Traefik e Mautic serão instalados."
	fi
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

	# 2. e-mail do Let's Encrypt, só onde o script emite certificado
	if [[ "$PA_CENARIO" != "2" ]] && [[ -z "$PA_EMAIL_ACME" ]]; then
		ui_vazio
		ui_info "O Let's Encrypt pede um e-mail para avisar sobre a"
		ui_info "renovação do certificado. Ele vai para a Let's Encrypt,"
		ui_info "não para a Play Ahead."
		ui_perguntar PA_EMAIL_ACME \
			"E-mail para o certificado SSL" \
			"" checks_validar_email
	fi

	# 3. e-mail do admin, com o do ACME como padrão
	if [[ -z "$PA_EMAIL_ADMIN" ]]; then
		local sugestao="${PA_EMAIL_ACME:-admin@${PA_DOMINIO}}"
		ui_vazio
		ui_perguntar PA_EMAIL_ADMIN \
			"E-mail para entrar no Mautic" \
			"$sugestao" checks_validar_email
	fi

	# 4. confirmação dos valores do Traefik, só no cenário 2
	if [[ "$PA_CENARIO" == "2" ]]; then
		main_confirmar_traefik
	fi

	# 5. subdomínio do Portainer, antecipado por --portainer.
	# A instalação continua sendo a última etapa; o que a flag
	# antecipa é só a pergunta.
	if [[ "$PA_PORTAINER" -eq 1 ]] && [[ -z "$PA_PORTAINER_DOMINIO" ]]; then
		ui_vazio
		ui_perguntar PA_PORTAINER_DOMINIO \
			"Subdomínio do Portainer (ex: portainer.suaempresa.com.br)" \
			"" checks_validar_dominio
	fi
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
	ui_secao "Preparando a máquina"

	if [[ "$PA_CENARIO" != "2" ]]; then
		sistema_criar_swap "$PA_NO_SWAP"
		docker_garantir
	fi

	if [[ "$PA_CENARIO" != "2" ]]; then
		traefik_instalar "$PA_EMAIL_ACME"
	fi

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
# Etapa 10 — Portainer
#
# Segunda exceção deliberada ao bloco único: a pergunta acontece
# aqui, depois da instalação. É o motivo de o Portainer vir por
# último — ele exige mais um apontamento de DNS, e uma falha dele
# aqui é aviso, não desastre, porque o Mautic já está de pé.
# ------------------------------------------------------------

main_portainer() {
	if [[ "$PA_PORTAINER" -eq 0 ]]; then
		ui_vazio
		if ! ui_confirmar "Quer instalar o Portainer para gerenciar os containers?" 0; then
			return 0
		fi
		PA_PORTAINER=1
	fi

	if [[ -z "$PA_PORTAINER_DOMINIO" ]]; then
		ui_perguntar PA_PORTAINER_DOMINIO \
			"Subdomínio do Portainer" "" checks_validar_dominio
	fi

	# Nenhuma função de portainer.sh chama ui_fatal, por decisão de
	# projeto: aqui o Mautic já está no ar, e uma falha do Portainer
	# é aviso, não desastre. Daí o `|| true`.
	portainer_instalar "$PA_PORTAINER_DOMINIO" || true

	portainer_anexar_credenciais "$PA_MAUTIC_CREDENCIAIS"
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

	if [[ -n "$PA_SWAP_CRIADO" ]]; then
		ui_vazio
		ui_info "Um arquivo de swap de 2 GB foi criado em ${PA_SWAP_CRIADO}"
		ui_info "porque esta máquina tem pouca memória."
	fi

	portainer_aviso_primeira_visita

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

	# Etapa 1
	checks_sistema

	# Etapa 2 e 3
	main_detectar_cenario

	# Etapa 4, antes de qualquer pergunta
	main_checar_instalacao_anterior

	# Etapa 5 e 6
	main_perguntar
	main_validar

	# Etapa 7 e 8
	main_instalar

	# Etapa 9. Não aborta: o Mautic está no ar de qualquer jeito, e
	# a regra do projeto é não derrubar nada quando algo dá errado.
	mautic_verificar_roteamento "$PA_DOMINIO" || true

	# Etapa 10
	main_portainer

	# Etapa 11
	main_bloco_final
}
