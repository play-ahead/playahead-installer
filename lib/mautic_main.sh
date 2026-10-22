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
# Os padrões ficam em constante própria porque o resumo compara
# o valor atual com eles para saber se a pessoa escolheu ou se o
# script trouxe de fábrica.
PA_IDIOMA_PADRAO="pt_BR"
PA_FUSO_PADRAO="America/Sao_Paulo"

PA_IDIOMA="$PA_IDIOMA_PADRAO"
PA_FUSO="$PA_FUSO_PADRAO"

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
        --admin-email=voce@exemplo.com.br --yes

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
# Etapa 2: a base está pronta?
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
	if [[ "${PA_PELO_MENU:-0}" == "1" ]]; then
		# Pelo menu, a base é a opção 1 da lista que volta em
		# seguida. Mandar baixar por curl seria apontar para fora.
		ui_info "O menu volta em seguida. Escolha a opção 1, a base, e"
		ui_info "depois esta de novo."
	else
		ui_info "Baixe, leia e rode a base:"
		ui_vazio
		ui_linha "    curl -sL https://get.playahead.com.br/base -o base.sh"
		ui_linha "    less base.sh"
		ui_linha "    sudo bash base.sh"
		ui_vazio
		ui_info "Terminada a base, rode este instalador de novo:"
		ui_vazio
		ui_linha "    sudo bash ${0}"
	fi
	ui_vazio
	ui_info "Nada foi alterado nesta máquina."
	ui_vazio

	exit 1
}

# ------------------------------------------------------------
# Etapa 4: instalação anterior
# ------------------------------------------------------------

main_checar_instalacao_anterior() {
	local estado
	estado="$(mautic_detectar_estado)"

	case "$estado" in
		perigoso) mautic_abortar_perigoso ;;
		retomar) main_preparar_retomada ;;
		nada)
			# Sobra de uma instalação que foi desmontada à mão.
			rm -f "$PA_MAUTIC_MARCA"
			;;
		concluida)
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

# main_preparar_retomada
#
# Instalação interrompida: existe .env, mas não a marca de
# concluída. Segue de onde parou, sem perguntar de novo o que já foi
# decidido. O domínio vem do .env e os valores do Traefik vêm do
# compose instalado, que nunca é sobrescrito; um --domain diferente
# para tudo, porque instalaria um domínio por cima de outro.
#
# A senha do admin, quando o mautic:install já tinha terminado, não
# está mais na memória de ninguém: vem do credenciais.txt, que
# passou a ser gravado logo depois do mautic:install.
main_preparar_retomada() {
	local dominio_env
	dominio_env="$(mautic_env_valor MAUTIC_DOMAIN)"

	if [[ -z "$dominio_env" ]]; then
		ui_fatal \
			"Encontrei uma instalação interrompida, mas o .env não diz o domínio." \
			"Falta a linha MAUTIC_DOMAIN= em ${PA_MAUTIC_ENV}." \
			"Confira o arquivo antes de rodar de novo."
	fi

	if [[ -n "$PA_DOMINIO" && "$PA_DOMINIO" != "$dominio_env" ]]; then
		ui_fatal \
			"Há uma instalação interrompida para outro domínio." \
			"" \
			"    em andamento: ${dominio_env}" \
			"    informado:    ${PA_DOMINIO}" \
			"" \
			"Este instalador retoma a instalação que parou, e não troca o" \
			"domínio dela. Rode sem --domain para retomar ${dominio_env}."
	fi

	PA_MAUTIC_RETOMANDO=1
	PA_DOMINIO="$dominio_env"

	# Os rótulos de origem são lidos por traefik_mostrar_deteccao.
	# shellcheck disable=SC2034
	if [[ -f "$PA_MAUTIC_COMPOSE" ]]; then
		PA_TRAEFIK_NETWORK="$(mautic_compose_label traefik.docker.network)"
		PA_TRAEFIK_ENTRYPOINT="$(mautic_compose_label traefik.http.routers.playahead-mautic.entrypoints)"
		PA_TRAEFIK_CERTRESOLVER="$(mautic_compose_label traefik.http.routers.playahead-mautic.tls.certresolver)"
		PA_TRAEFIK_NETWORK_ORIGEM="lido do compose em andamento"
		PA_TRAEFIK_ENTRYPOINT_ORIGEM="lido do compose em andamento"
		PA_TRAEFIK_CERTRESOLVER_ORIGEM="lido do compose em andamento"
	fi

	mautic_ler_credenciais

	ui_secao "Instalação interrompida encontrada"
	ui_info "Uma instalação anterior parou antes do fim. Vou retomar"
	ui_info "de onde ela parou, com o que já está em ${PA_MAUTIC_DIR}:"
	ui_detalhe "domínio:  ${PA_DOMINIO}"
	if mautic_site_url_gravado; then
		ui_detalhe "o Mautic já foi instalado; falta o que vem depois"
	else
		ui_detalhe "o Mautic ainda não foi instalado"
	fi
	ui_vazio
	ui_info "Nada será apagado, e a senha do banco continua a mesma."
	ui_vazio
}

# ------------------------------------------------------------
# Etapa 5: bloco único de perguntas
# ------------------------------------------------------------

# main_validar_email_admin <email>
#
# O validador do e-mail do bloco de perguntas, com uma guarda a
# mais: a parte antes do arroba não pode conter o domínio que
# acabou de ser respondido.
#
# Defesa contra o erro de 2026-09-30, em que uma colagem deixou
# sobra na fila do terminal e a pergunta seguinte leu o domínio
# grudado no e-mail, gravando
# "testemautic.exemplo.comfabioroger7@yahoo.com.br".
#
# Vale registrar por que nenhuma validação genérica de e-mail
# pega esse valor: ele é sintaticamente válido, com 45
# caracteres antes do arroba e um domínio real. Só quem sabe o
# que foi respondido na pergunta anterior consegue saber que
# esta errado.
#
# O ui_descartar_entrada já evita a causa. Esta guarda fica
# porque custa uma comparação de string e o erro custou uma
# instalação inteira.
main_validar_email_admin() {
	local email="$1"

	checks_validar_email "$email" || return 1

	local parte_local="${email%@*}"

	if [[ -n "$PA_DOMINIO" ]] && [[ "$parte_local" == *"$PA_DOMINIO"* ]]; then
		ui_aviso "Este e-mail tem o domínio grudado antes do arroba."
		ui_detalhe "domínio respondido: ${PA_DOMINIO}"
		ui_detalhe "antes do arroba:   ${parte_local}"
		ui_detalhe "Costuma ser sobra de colagem. Digite só o e-mail."
		return 1
	fi

	return 0
}

main_perguntar() {
	# Na retomada, domínio e Traefik já foram decididos na primeira
	# vez. O e-mail do admin só falta quando o mautic:install ainda
	# não rodou; depois dele, o e-mail vem do credenciais.txt ou do
	# banco, e perguntar de novo poderia gravar um que não é o real.
	if [[ "$PA_MAUTIC_RETOMANDO" -eq 1 ]]; then
		if [[ -z "$PA_EMAIL_ADMIN" ]] && ! mautic_site_url_gravado; then
			ui_perguntar PA_EMAIL_ADMIN \
				"E-mail para entrar no Mautic" \
				"admin@${PA_DOMINIO}" main_validar_email_admin
		fi
		return 0
	fi

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
		ui_perguntar PA_EMAIL_ADMIN \
			"E-mail para entrar no Mautic" \
			"$sugestao" main_validar_email_admin
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
# Etapa 6: validação
# ------------------------------------------------------------

main_validar() {
	ui_secao "Conferindo o domínio"

	if [[ "$PA_SKIP_DNS" -eq 1 ]]; then
		PA_DNS_RESULTADO="não verificado, por --skip-dns-check"
		ui_aviso "Validação de DNS pulada por --skip-dns-check."
		return 0
	fi

	checks_ip_publico || true
	checks_dns "$PA_DOMINIO"
}

# ------------------------------------------------------------
# Confirmação
# ------------------------------------------------------------

# main_confirmar
#
# Último ponto antes de escrever qualquer coisa. Mostra tudo que
# foi decidido e pede licença para começar.
#
# Vem depois da validação de DNS, e não antes, para o resumo poder
# dizer o que a validação concluiu. Um "aponta para esta VPS" na
# tela vale mais que a promessa de que foi verificado.
main_confirmar() {
	local certresolver="${PA_TRAEFIK_CERTRESOLVER:-omitido}"

	local conclusao="concluir pela linha de comando"
	local origem_conclusao="padrao"
	if [[ "$PA_WIZARD" -eq 1 ]]; then
		conclusao="deixar o assistente web (--wizard)"
		origem_conclusao="informado"
	fi

	# Idioma e fuso: comparar com o padrão distingue "a pessoa
	# escolheu" de "o script trouxe de fábrica" sem precisar
	# guardar mais estado no parse. Quem passar --idioma=pt_BR
	# explicitamente aparece como padrão, e isso não incomoda
	# ninguém.
	local origem_idioma="padrao"
	local origem_fuso="padrao"
	[[ "$PA_IDIOMA" != "$PA_IDIOMA_PADRAO" ]] && origem_idioma="informado"
	[[ "$PA_FUSO" != "$PA_FUSO_PADRAO" ]] && origem_fuso="informado"

	# Os três valores do Traefik entram como detectado mesmo
	# quando vieram de flag: a tela anterior, a do
	# main_confirmar_traefik, já mostrou a origem de cada um numa
	# tabela própria, e repetir aqui só tiraria peso da marca de
	# "veio de você" nas duas linhas que importam.
	# Na retomada o domínio e o e-mail vêm da instalação anterior, e
	# não da pessoa: marcá-los como "veio de você" pediria conferência
	# de um valor que ela não digitou agora.
	local origem_dominio="informado"
	local origem_email="informado"
	local email_mostrado="$PA_EMAIL_ADMIN"
	local situacao="instalação nova"
	if [[ "$PA_MAUTIC_RETOMANDO" -eq 1 ]]; then
		origem_dominio="detectado"
		situacao="retomando a instalação interrompida"
		if [[ -z "$PA_EMAIL_ADMIN" ]]; then
			email_mostrado="o que já está no banco"
			origem_email="detectado"
		elif mautic_site_url_gravado; then
			origem_email="detectado"
		fi
	fi

	ui_resumo "Confira antes de começar" \
		"Situação" "$situacao" detectado \
		"Domínio" "https://${PA_DOMINIO}" "$origem_dominio" \
		"E-mail do admin" "$email_mostrado" "$origem_email" \
		"DNS" "$PA_DNS_RESULTADO" detectado \
		"Rede do Traefik" "${PA_TRAEFIK_NETWORK:-traefik_public}" detectado \
		"Entrypoint" "${PA_TRAEFIK_ENTRYPOINT:-websecure}" detectado \
		"Certresolver" "$certresolver" detectado \
		"Idioma" "$PA_IDIOMA" "$origem_idioma" \
		"Fuso horário" "$PA_FUSO" "$origem_fuso" \
		"Pasta" "$PA_MAUTIC_DIR" padrao \
		"Conclusão" "$conclusao" "$origem_conclusao"

	ui_confirmar_resumo
}

# ------------------------------------------------------------
# Etapas 7 e 8: instalação
# ------------------------------------------------------------

main_instalar() {
	ui_secao "Instalando o Mautic"

	mautic_gravar_compose "$PA_TEMPLATE_MAUTIC"
	mautic_gerar_env "$PA_DOMINIO"

	mautic_baixar_imagens
	mautic_subir_banco
	mautic_subir_web

	# Antes da instalação, e fora do if, porque vale para os três
	# caminhos: linha de comando, --wizard e reexecução sobre uma
	# instalação que já existe. É o passo que evita o laço de
	# redirecionamento, e é idempotente.
	mautic_gravar_proxies || true

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

		if [[ "$PA_MAUTIC_JA_INSTALADO" -eq 0 ]]; then
			# Logo depois do mautic:install, e de novo no fim: a senha
			# do admin só existe na memória deste processo, e uma queda
			# daqui até o fim a levaria junto. O "Esqueceu a senha" do
			# Mautic depende de SMTP, que o script não configura.
			mautic_gravar_credenciais "$PA_DOMINIO" "$PA_EMAIL_ADMIN"
		elif [[ -z "$PA_EMAIL_ADMIN" ]]; then
			# Retomada depois do mautic:install sem credenciais.txt.
			PA_EMAIL_ADMIN="$(mautic_email_admin_do_banco)"
		fi

		# Sempre que o script chega aqui, inclusive na retomada:
		# instalação concluída sai antes, em
		# main_checar_instalacao_anterior, então nada que a pessoa
		# tenha configurado no painel é sobrescrito. Na retomada, a
		# queda pode ter sido justamente no meio desta etapa.
		mautic_regionalizar "$PA_IDIOMA" "$PA_FUSO"
	fi

	mautic_subir_resto

	# Antes das credenciais, porque o resultado vai para o arquivo.
	mautic_testar_smtp
	mautic_gravar_credenciais "$PA_DOMINIO" "$PA_EMAIL_ADMIN"
}

# ------------------------------------------------------------
# Etapa 11: bloco final
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
	elif [[ "$PA_MAUTIC_JA_INSTALADO" -eq 1 && -z "$PA_MAUTIC_SENHA_ADMIN" ]]; then
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

	# Medido em 2026-10-22: o IP público está na placa de rede, e a
	# requisição da conferência nem sai da máquina. Um firewall do
	# provedor fechando a 443 não apareceria nela.
	ui_vazio
	ui_info "A conferência do endereço rodou de dentro desta VPS e não"
	ui_info "passa pelo firewall do provedor. Abra no navegador para ter"
	ui_info "certeza: https://${PA_DOMINIO}"

	# Repetido aqui porque o aviso da etapa já rolou para fora da
	# tela, e esta é a primeira coisa que a pessoa vai configurar.
	if [[ "$PA_SMTP_587" == "bloqueada" ]]; then
		ui_vazio
		if [[ "$PA_SMTP_2587" == "aberta" ]]; then
			ui_aviso "A porta 587 está bloqueada nesta VPS."
			ui_detalhe "No Amazon SES, configure a porta 2587 no painel."
		else
			ui_aviso "A saída SMTP está bloqueada nesta VPS (587 e 2587)."
			ui_detalhe "Peça a liberação ao provedor antes de configurar o e-mail."
		fi
		ui_detalhe "Detalhes em ${PA_MAUTIC_CREDENCIAIS}."
	fi

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
	main_confirmar
	main_instalar

	# Não aborta: o Mautic está no ar de qualquer jeito, e a regra do
	# projeto é não derrubar nada quando algo dá errado.
	mautic_verificar_roteamento "$PA_DOMINIO" || true

	# Último passo. A verificação acima não conta: ela avisa sem
	# derrubar, e o Mautic está instalado de qualquer jeito.
	mautic_gravar_marca

	main_bloco_final
}
