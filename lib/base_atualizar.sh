#!/usr/bin/env bash
# shellcheck shell=bash
#
# ============================================================
# lib/base_atualizar.sh
# Modo de atualização da base:
#
#     sudo bash base.sh --atualizar
#
# Leva o Traefik e o Portainer que esta base instalou para as
# versões recomendadas deste instalador. Nunca sozinho: é ação
# pedida, com confirmação na tela. O Docker não entra: ele chega
# pelo apt, junto com o resto do sistema.
#
# Só mexe no que é nosso. Traefik ou Portainer que não estão em
# /opt/playahead foram instalados por outra pessoa ou outro script,
# e ficam como estão.
#
# Mesma ordem do modo de atualização do Mautic: confere, baixa a
# imagem nova com tudo ainda no ar, faz o backup, e só então troca.
# Não há volta automática; saindo com erro depois do backup, a tela
# mostra os comandos para voltar.
#
# É, com a atualização do Mautic, a única exceção à regra de não
# sobrescrever compose: a versão mora no compose, e é o único caminho
# para uma instalação antiga receber as correções dele (a rotação de
# log, por exemplo). O compose antigo vai para o backup antes. Os
# arquivos .env e admin_password nunca são tocados.
# ============================================================

# 1 quando o script foi chamado com --atualizar.
PA_ATUALIZAR=0

PA_BASE_BACKUPS="/opt/playahead/backups"

# Preenchidas no planejamento. Em cada peça: "sim" quando há o que
# trocar, "nao" quando está em dia, "fora" quando não é nossa.
PA_BASE_BACKUP=""
PA_BASE_TRAEFIK="fora"
PA_BASE_TRAEFIK_DE=""
PA_BASE_PORTAINER="fora"
PA_BASE_PORTAINER_DE=""

# 1 do fim do backup até o fim da atualização.
PA_BASE_TROCANDO=0

# 1 depois que o Portainer foi parado para o backup. Saindo com erro
# antes de qualquer troca, é o que faz a saída ligá-lo de novo.
PA_BASE_PORTAINER_PARADO=0

PA_BASE_VOLUME_ACME="playahead_traefik_letsencrypt"
PA_BASE_VOLUME_PORTAINER="playahead_portainer_data"

# ------------------------------------------------------------
# Leitura do que está instalado
# ------------------------------------------------------------

# base_atualizar_versao_em_uso <pasta> <servico> <expressao>
#
# A versão do container, lida da tag da imagem. Na base a tag sempre
# foi número exato, então ela basta. Nada quando a imagem não é a
# que este instalador grava.
base_atualizar_versao_em_uso() {
	local imagem
	imagem="$(docker_imagem_do_servico "$1" "$2")"
	if [[ "$imagem" =~ $3 ]]; then
		printf '%s\n' "${BASH_REMATCH[1]}"
	fi
}

# base_atualizar_label_portainer <nome>
#
# Um valor do compose instalado do Portainer. O compose novo é
# montado com o que a instalação decidiu (domínio, entrypoint,
# certresolver e rede), e não com uma detecção nova: atualizar não é
# hora de mudar roteamento.
base_atualizar_label_portainer() {
	sed -n "s/^ *- \"traefik\.${1}=\(.*\)\"\$/\1/p" \
		"${PA_PORTAINER_DIR}/docker-compose.yml" | head -n 1
}

# base_atualizar_ler_portainer
#
# Preenche as variáveis que o portainer_gerar_compose usa. Devolve 1
# quando o compose instalado não tem o que se espera, sinal de que
# foi reescrito à mão.
base_atualizar_ler_portainer() {
	local regra
	regra="$(base_atualizar_label_portainer 'http\.routers\.playahead-portainer\.rule')"

	# Host(`painel.exemplo.com.br`)
	PA_PORTAINER_DOMINIO="${regra#*\`}"
	PA_PORTAINER_DOMINIO="${PA_PORTAINER_DOMINIO%%\`*}"

	PA_TRAEFIK_ENTRYPOINT="$(base_atualizar_label_portainer 'http\.routers\.playahead-portainer\.entrypoints')"
	PA_TRAEFIK_CERTRESOLVER="$(base_atualizar_label_portainer 'http\.routers\.playahead-portainer\.tls\.certresolver')"
	PA_TRAEFIK_NETWORK="$(base_atualizar_label_portainer 'docker\.network')"

	[[ -n "$regra" && "$regra" == *'`'* && -n "$PA_PORTAINER_DOMINIO" &&
		-n "$PA_TRAEFIK_ENTRYPOINT" && -n "$PA_TRAEFIK_NETWORK" ]]
}

# ------------------------------------------------------------
# Planejamento
# ------------------------------------------------------------

# base_atualizar_recusar_volta <nome> <de> <para>
#
# Versão em uso mais nova que a recomendada deste instalador:
# "atualizar" seria voltar versão.
base_atualizar_recusar_volta() {
	docker_versao_maior "$2" "$3" || return 0

	ui_fatal \
		"O ${1} em uso (${2}) é mais novo que o recomendado deste instalador (${3})." \
		"Atualizar seria voltar versão." \
		"" \
		"Baixe o instalador mais recente e rode a atualização com ele:" \
		"" \
		"    https://get.playahead.com.br/base" \
		"" \
		"Nada foi alterado."
}

# base_atualizar_planejar_traefik
base_atualizar_planejar_traefik() {
	local compose="${PA_TRAEFIK_DIR}/docker-compose.yml"

	if [[ ! -f "$compose" ]]; then
		ui_info "Traefik: não foi instalado por esta base; fica como está."
		return 0
	fi

	PA_BASE_TRAEFIK_DE="$(base_atualizar_versao_em_uso "$PA_TRAEFIK_DIR" traefik \
		'^traefik:(v3\.[0-9]+\.[0-9]+)$')"

	if [[ -z "$PA_BASE_TRAEFIK_DE" ]]; then
		ui_aviso "Traefik: não reconheci a versão em uso; fica como está."
		ui_detalhe "imagem: $(docker_imagem_do_servico "$PA_TRAEFIK_DIR" traefik)"
		ui_detalhe "Este instalador só atualiza o Traefik v3 que ele mesmo subiu."
		return 0
	fi

	base_atualizar_recusar_volta "Traefik" "$PA_BASE_TRAEFIK_DE" "$PA_TRAEFIK_VERSAO"

	traefik_gerar_compose "${compose}.novo"

	if [[ "$PA_BASE_TRAEFIK_DE" == "$PA_TRAEFIK_VERSAO" ]] &&
		cmp -s "${compose}.novo" "$compose"; then
		rm -f "${compose}.novo"
		PA_BASE_TRAEFIK="nao"
		ui_ok "Traefik ${PA_BASE_TRAEFIK_DE}: já é a versão recomendada"
		return 0
	fi

	PA_BASE_TRAEFIK="sim"
	ui_ok "Traefik ${PA_BASE_TRAEFIK_DE} em uso; o recomendado é o ${PA_TRAEFIK_VERSAO}"
}

# base_atualizar_planejar_portainer
base_atualizar_planejar_portainer() {
	local compose="${PA_PORTAINER_DIR}/docker-compose.yml"

	if [[ ! -f "$compose" ]]; then
		ui_info "Portainer: não foi instalado por esta base; fica como está."
		return 0
	fi

	PA_BASE_PORTAINER_DE="$(base_atualizar_versao_em_uso "$PA_PORTAINER_DIR" portainer \
		'^portainer/portainer-ce:(2\.[0-9]+\.[0-9]+)$')"

	if [[ -z "$PA_BASE_PORTAINER_DE" ]]; then
		ui_aviso "Portainer: não reconheci a versão em uso; fica como está."
		ui_detalhe "imagem: $(docker_imagem_do_servico "$PA_PORTAINER_DIR" portainer)"
		return 0
	fi

	if ! base_atualizar_ler_portainer; then
		ui_aviso "Portainer: não reconheci o compose instalado; fica como está."
		ui_detalhe "Faltou o domínio, o entrypoint ou a rede em ${compose}."
		return 0
	fi

	base_atualizar_recusar_volta "Portainer" "$PA_BASE_PORTAINER_DE" "$PA_PORTAINER_VERSAO"

	portainer_gerar_compose "${compose}.novo"

	if [[ "$PA_BASE_PORTAINER_DE" == "$PA_PORTAINER_VERSAO" ]] &&
		cmp -s "${compose}.novo" "$compose"; then
		rm -f "${compose}.novo"
		PA_BASE_PORTAINER="nao"
		ui_ok "Portainer ${PA_BASE_PORTAINER_DE}: já é a versão recomendada"
		return 0
	fi

	PA_BASE_PORTAINER="sim"
	ui_ok "Portainer ${PA_BASE_PORTAINER_DE} em uso; o recomendado é o ${PA_PORTAINER_VERSAO}"
}

# base_atualizar_planejar
#
# Não altera nada além de gravar o compose novo num arquivo ao lado
# do instalado.
base_atualizar_planejar() {
	ui_secao "Conferindo a base"

	if ! docker_presente || ! docker_compose_presente; then
		ui_fatal \
			"Não encontrei o Docker nesta máquina." \
			"Não há base para atualizar. Para instalar, rode sem --atualizar:" \
			"" \
			"    sudo bash ${0}"
	fi
	docker_checar_swarm

	base_atualizar_planejar_traefik
	base_atualizar_planejar_portainer

	if [[ "$PA_BASE_TRAEFIK" != "sim" && "$PA_BASE_PORTAINER" != "sim" ]]; then
		ui_vazio
		if [[ "$PA_BASE_TRAEFIK" == "fora" && "$PA_BASE_PORTAINER" == "fora" ]]; then
			ui_info "Não há nada desta base para atualizar nesta VPS."
		else
			ui_info "Nada a atualizar: a base já está nas versões recomendadas."
		fi
		ui_info "Nada foi alterado nesta máquina."
		ui_vazio
		exit 0
	fi

	PA_BASE_BACKUP="${PA_BASE_BACKUPS}/base-$(date +%Y-%m-%d-%H%M%S)"
}

# ------------------------------------------------------------
# Confirmação
# ------------------------------------------------------------

# base_atualizar_descrever <situacao> <de> <para>
base_atualizar_descrever() {
	case "$1" in
		fora) printf 'não é desta base, fica como está\n' ;;
		nao) printf '%s (sem mudança)\n' "$2" ;;
		*)
			if [[ "$2" == "$3" ]]; then
				printf '%s, só o compose muda\n' "$2"
			else
				printf '%s para %s\n' "$2" "$3"
			fi
			;;
	esac
}

# base_atualizar_avisar_compose <nome> <pasta>
#
# Se a pessoa mexeu no compose, ela precisa saber antes que a
# alteração não vai junto.
base_atualizar_avisar_compose() {
	case "$(docker_compose_situacao "$2")" in
		intacto) return 0 ;;
		alterado)
			ui_vazio
			ui_aviso "O compose do ${1} foi alterado depois da instalação."
			ui_detalhe "A alteração NÃO vai junto: o arquivo é regravado a partir"
			ui_detalhe "deste instalador. O antigo fica guardado no backup."
			ui_detalhe "Se ela ainda for necessária, refaça no arquivo novo depois."
			;;
		*)
			ui_vazio
			ui_aviso "Não sei dizer se o compose do ${1} foi alterado à mão."
			ui_detalhe "Esta instalação é anterior ao registro que permite conferir."
			ui_detalhe "Se você mexeu nele, a alteração NÃO vai junto: o arquivo é"
			ui_detalhe "regravado. O antigo fica guardado no backup."
			;;
	esac
}

# base_atualizar_confirmar
#
# O resumo sai sempre, inclusive com --yes. A pergunta tem "não"
# como resposta do Enter: trocar o Traefik tira todos os sites desta
# VPS do ar por alguns segundos.
base_atualizar_confirmar() {
	ui_resumo "Confira antes de atualizar" \
		"Traefik" "$(base_atualizar_descrever "$PA_BASE_TRAEFIK" "$PA_BASE_TRAEFIK_DE" "$PA_TRAEFIK_VERSAO")" detectado \
		"Portainer" "$(base_atualizar_descrever "$PA_BASE_PORTAINER" "$PA_BASE_PORTAINER_DE" "$PA_PORTAINER_VERSAO")" detectado \
		"Backup" "$PA_BASE_BACKUP" padrao

	if [[ "$PA_BASE_TRAEFIK" == "sim" ]]; then
		ui_info "Trocar o Traefik tira TODOS os sites desta VPS do ar por"
		ui_info "alguns segundos. Os certificados continuam os mesmos."
		base_atualizar_avisar_compose "Traefik" "$PA_TRAEFIK_DIR"
	fi
	if [[ "$PA_BASE_PORTAINER" == "sim" ]]; then
		ui_vazio
		ui_info "O Portainer fica fora do ar durante a troca dele. O usuário"
		ui_info "e a senha continuam os mesmos."
		base_atualizar_avisar_compose "Portainer" "$PA_PORTAINER_DIR"
	fi
	ui_vazio

	ui_interativo || return 0

	if ui_confirmar "Posso atualizar?" 0; then
		return 0
	fi

	rm -f "${PA_TRAEFIK_DIR}/docker-compose.yml.novo" \
		"${PA_PORTAINER_DIR}/docker-compose.yml.novo"
	ui_vazio
	ui_info "Nada foi alterado nesta máquina."
	ui_vazio
	exit 0
}

# ------------------------------------------------------------
# Imagens e backup
# ------------------------------------------------------------

# base_atualizar_baixar
#
# Antes de parar qualquer coisa. Falhando aqui, nada mudou.
base_atualizar_baixar() {
	ui_passo "Baixando as imagens novas"

	local imagens=() imagem
	[[ "$PA_BASE_TRAEFIK" == "sim" ]] && imagens+=("traefik:${PA_TRAEFIK_VERSAO}")
	[[ "$PA_BASE_PORTAINER" == "sim" ]] &&
		imagens+=("portainer/portainer-ce:${PA_PORTAINER_VERSAO}")

	for imagem in "${imagens[@]}"; do
		if docker image inspect "$imagem" >/dev/null 2>&1; then
			ui_ok "${imagem} já está nesta máquina"
			continue
		fi
		if ! docker pull "$imagem"; then
			rm -f "${PA_TRAEFIK_DIR}/docker-compose.yml.novo" \
				"${PA_PORTAINER_DIR}/docker-compose.yml.novo"
			ui_fatal \
				"Não consegui baixar ${imagem}." \
				"Nada foi alterado, e a base segue no ar como estava." \
				"Confira a conexão da VPS com o Docker Hub e rode de novo."
		fi
		ui_ok "${imagem} baixada"
	done
}

# base_atualizar_backup
#
# Tudo que a atualização pode estragar, numa pasta legível só por
# root: o acme.json tem as chaves dos certificados, e os dados do
# Portainer têm a senha dele (com hash) e o acesso aos containers.
#
# O Portainer é parado antes da cópia dos dados, para o arquivo do
# banco dele não ser copiado no meio de uma escrita.
base_atualizar_backup() {
	ui_passo "Fazendo o backup"

	local mascara_antiga origem
	mascara_antiga="$(umask)"
	umask 077

	mkdir -p "$PA_BASE_BACKUP"
	chmod 700 "$PA_BASE_BACKUPS" "$PA_BASE_BACKUP"

	if [[ "$PA_BASE_TRAEFIK" == "sim" ]]; then
		mkdir -p "${PA_BASE_BACKUP}/traefik"
		cp -p "${PA_TRAEFIK_DIR}/docker-compose.yml" "${PA_BASE_BACKUP}/traefik/"
		[[ -f "${PA_TRAEFIK_DIR}/.env" ]] &&
			cp -p "${PA_TRAEFIK_DIR}/.env" "${PA_BASE_BACKUP}/traefik/"

		origem="$(docker volume inspect -f '{{.Mountpoint}}' "$PA_BASE_VOLUME_ACME" 2>/dev/null)" || true
		if [[ -n "$origem" && -f "${origem}/acme.json" ]]; then
			cp -p "${origem}/acme.json" "${PA_BASE_BACKUP}/traefik/"
			ui_ok "Traefik: compose e certificados (acme.json)"
		else
			ui_ok "Traefik: compose"
		fi
	fi

	if [[ "$PA_BASE_PORTAINER" == "sim" ]]; then
		mkdir -p "${PA_BASE_BACKUP}/portainer"
		cp -p "${PA_PORTAINER_DIR}/docker-compose.yml" "${PA_BASE_BACKUP}/portainer/"

		PA_BASE_PORTAINER_PARADO=1
		(cd "$PA_PORTAINER_DIR" && docker compose stop portainer >/dev/null 2>&1) || true

		origem="$(docker volume inspect -f '{{.Mountpoint}}' "$PA_BASE_VOLUME_PORTAINER" 2>/dev/null)" || true
		if [[ -z "$origem" || ! -d "$origem" ]] ||
			! tar -czf "${PA_BASE_BACKUP}/portainer/dados.tar.gz" -C "$origem" . 2>/dev/null; then
			umask "$mascara_antiga"
			ui_fatal \
				"Não consegui copiar os dados do Portainer para o backup." \
				"A atualização parou aqui."
		fi
		ui_ok "Portainer: compose e dados"
	fi

	base_atualizar_como_restaurar arquivo >"${PA_BASE_BACKUP}/COMO-RESTAURAR.txt"

	# Fecha o que foi criado, sem depender do umask: em pasta com ACL
	# padrão ele não vale. Ver o comentário de mautic_fazer_backup.
	chmod -R go-rwx "$PA_BASE_BACKUP"

	umask "$mascara_antiga"

	ui_ok "Backup completo em ${PA_BASE_BACKUP}"
}

# ------------------------------------------------------------
# Como restaurar
# ------------------------------------------------------------

# base_atualizar_como_restaurar
#
# O mesmo texto vai para a tela, quando a atualização sai com erro,
# e para o arquivo COMO-RESTAURAR.txt dentro do backup.
base_atualizar_como_restaurar() {
	# Na tela, o texto vem depois de uma atualização que saiu com
	# erro. No arquivo do backup ele é lido meses depois, por quem
	# não está no meio de atualização nenhuma.
	printf '\n'
	if [[ "${1:-}" == "arquivo" ]]; then
		printf '  Backup feito em %s, antes de atualizar a base.\n' "$(date +%Y-%m-%d)"
		printf '\n'
		printf '  Pasta deste backup:\n'
		printf '      %s\n' "$PA_BASE_BACKUP"
	else
		printf '  A atualização da base não terminou.\n'
		printf '\n'
		printf '  O backup de antes dela está em:\n'
		printf '      %s\n' "$PA_BASE_BACKUP"
		printf '\n'
		printf '  PARA TENTAR DE NOVO:\n'
		printf '\n'
		printf '      sudo bash %s --atualizar\n' "$0"
	fi

	if [[ "$PA_BASE_TRAEFIK" == "sim" ]]; then
		printf '\n'
		printf '  PARA VOLTAR o Traefik ao %s:\n' "$PA_BASE_TRAEFIK_DE"
		printf '\n'
		printf '      cd %s\n' "$PA_TRAEFIK_DIR"
		printf '      cp %s/traefik/docker-compose.yml docker-compose.yml\n' "$PA_BASE_BACKUP"
		printf '      rm -f .compose.sha256\n'
		printf '      docker compose up -d\n'
	fi

	if [[ "$PA_BASE_PORTAINER" == "sim" ]]; then
		printf '\n'
		printf '  PARA VOLTAR o Portainer ao %s, com os dados de antes:\n' "$PA_BASE_PORTAINER_DE"
		printf '\n'
		printf '      cd %s\n' "$PA_PORTAINER_DIR"
		printf '      docker compose down -v\n'
		printf '      cp %s/portainer/docker-compose.yml docker-compose.yml\n' "$PA_BASE_BACKUP"
		printf '      rm -f .compose.sha256\n'
		printf '      docker compose up --no-start\n'
		printf '      tar -xzf %s/portainer/dados.tar.gz \\\n' "$PA_BASE_BACKUP"
		# As aspas e o cifrão são do comando que a pessoa vai colar.
		# shellcheck disable=SC2016
		printf '        -C "$(docker volume inspect -f %s %s)"\n' \
			"'{{.Mountpoint}}'" "$PA_BASE_VOLUME_PORTAINER"
		printf '      docker compose up -d\n'
		printf '\n'
		printf '  O "down -v" apaga os dados atuais do Portainer; o tar devolve\n'
		printf '  os do backup. Os outros containers não são afetados.\n'
	fi
	printf '\n'
}

# base_atualizar_ao_sair
#
# Tratador de saída da atualização, para erro e para Ctrl-C. Depois
# do backup, mostra como voltar. Antes dele, nada foi trocado: liga
# de novo o Portainer, se ele foi parado para a cópia dos dados.
# Escreve na cópia da tela guardada pelo ui_tratar_interrupcao.
base_atualizar_ao_sair() {
	local codigo=$?

	if [[ "$codigo" -ne 0 && "$PA_BASE_TROCANDO" -eq 1 ]]; then
		base_atualizar_como_restaurar >&"$PA_UI_FD_TELA" 2>&1 || true
	elif [[ "$codigo" -ne 0 && "$PA_BASE_PORTAINER_PARADO" -eq 1 ]]; then
		printf '  Nada foi trocado. Ligando o Portainer de novo.\n' \
			>&"$PA_UI_FD_TELA" 2>&1 || true
		# Espera a parada terminar antes de ligar: um "stop"
		# interrompido continua valendo dentro do Docker, e ligar na
		# hora não teria efeito. Ver mautic_atualizar_religar.
		docker_compose_desligado "$PA_PORTAINER_DIR" stop portainer || true
		docker_compose_desligado "$PA_PORTAINER_DIR" start portainer || true
		{
			printf '  Portainer ligado. Para tentar outra vez:\n'
			printf '      sudo bash %s --atualizar\n\n' "$0"
		} >&"$PA_UI_FD_TELA" 2>&1 || true
	fi

	ui_restaurar_terminal
}

# ------------------------------------------------------------
# A troca
# ------------------------------------------------------------

# base_atualizar_trocar_traefik
base_atualizar_trocar_traefik() {
	[[ "$PA_BASE_TRAEFIK" == "sim" ]] || return 0

	ui_passo "Trocando o Traefik para o ${PA_TRAEFIK_VERSAO}"

	mv -f "${PA_TRAEFIK_DIR}/docker-compose.yml.novo" "${PA_TRAEFIK_DIR}/docker-compose.yml"
	docker_compose_registrar_hash "$PA_TRAEFIK_DIR"

	docker_compose_desligado "$PA_TRAEFIK_DIR" up -d ||
		ui_fatal \
			"Falha ao subir o Traefik ${PA_TRAEFIK_VERSAO}." \
			"Rode à mão para ver o erro:" \
			"" \
			"    cd ${PA_TRAEFIK_DIR} && docker compose up -d"

	ui_aguardar_ate "Aguardando o Traefik ocupar as portas 80 e 443" 90 \
		traefik_portas_ocupadas ||
		ui_fatal \
			"O Traefik subiu mas não está ouvindo em 80 e 443." \
			"Veja o log:" \
			"" \
			"    cd ${PA_TRAEFIK_DIR} && docker compose logs traefik"

	local subiu
	subiu="$(base_atualizar_versao_em_uso "$PA_TRAEFIK_DIR" traefik '^traefik:(v3\.[0-9]+\.[0-9]+)$')"
	if [[ "$subiu" == "$PA_TRAEFIK_VERSAO" ]]; then
		ui_ok "Traefik ${subiu} no ar"
	else
		ui_aviso "O Traefik subiu, mas a imagem em uso é a ${subiu:-desconhecida}."
	fi
}

# base_atualizar_trocar_portainer
#
# Avisa em vez de parar quando o Portainer não responde: nessa hora
# o Traefik já foi trocado e está no ar, e os sites não dependem do
# Portainer.
base_atualizar_trocar_portainer() {
	[[ "$PA_BASE_PORTAINER" == "sim" ]] || return 0

	ui_passo "Trocando o Portainer para o ${PA_PORTAINER_VERSAO}"

	mv -f "${PA_PORTAINER_DIR}/docker-compose.yml.novo" "${PA_PORTAINER_DIR}/docker-compose.yml"
	docker_compose_registrar_hash "$PA_PORTAINER_DIR"

	docker_compose_desligado "$PA_PORTAINER_DIR" up -d ||
		ui_fatal \
			"Falha ao subir o Portainer ${PA_PORTAINER_VERSAO}." \
			"Rode à mão para ver o erro:" \
			"" \
			"    cd ${PA_PORTAINER_DIR} && docker compose up -d"

	ui_aguardar_ate "Aguardando o Portainer responder" 120 portainer_respondendo ||
		ui_fatal \
			"O Portainer novo subiu mas não ficou no ar." \
			"Veja o log:" \
			"" \
			"    cd ${PA_PORTAINER_DIR} && docker compose logs"

	ui_ok "Portainer ${PA_PORTAINER_VERSAO} no ar"

	portainer_verificar_roteamento "$PA_PORTAINER_DOMINIO" || true
}

# ------------------------------------------------------------
# Bloco final
# ------------------------------------------------------------

base_atualizar_bloco_final() {
	ui_vazio
	ui_secao "Atualização concluída"

	ui_info "Traefik:   $(base_atualizar_descrever "$PA_BASE_TRAEFIK" "$PA_BASE_TRAEFIK_DE" "$PA_TRAEFIK_VERSAO")"
	ui_info "Portainer: $(base_atualizar_descrever "$PA_BASE_PORTAINER" "$PA_BASE_PORTAINER_DE" "$PA_PORTAINER_VERSAO")"
	ui_vazio
	ui_info "Backup de antes da atualização:"
	ui_detalhe "$PA_BASE_BACKUP"
	ui_detalhe "Como voltar, se precisar: COMO-RESTAURAR.txt, dentro dele."
	ui_detalhe "O instalador não apaga backup. Quando tiver certeza de que"
	ui_detalhe "está tudo certo, apague a pasta para liberar espaço."
	ui_vazio
	ui_info "Abra os seus sites no navegador para conferir."
	if [[ "$PA_BASE_PORTAINER" == "sim" ]]; then
		ui_detalhe "Portainer: https://${PA_PORTAINER_DOMINIO}"
	fi
	ui_vazio
}

# ------------------------------------------------------------
# Orquestração
# ------------------------------------------------------------

# base_atualizar
#
# Chamado pelo main quando há --atualizar.
base_atualizar() {
	base_atualizar_planejar
	base_atualizar_confirmar

	ui_secao "Atualizando a base"

	# A dica do Ctrl-C da instalação fala em reaproveitar o que foi
	# instalado. Aqui o que vale é a da atualização.
	PA_UI_DICA_INTERRUPCAO=("Para continuar a atualização, rode o mesmo comando de novo.")
	trap base_atualizar_ao_sair EXIT

	base_atualizar_baixar

	ui_marcar_alteracao
	base_atualizar_backup

	# Daqui em diante, sair com erro mostra como voltar.
	PA_BASE_TROCANDO=1

	base_atualizar_trocar_traefik
	base_atualizar_trocar_portainer

	PA_BASE_TROCANDO=0

	base_atualizar_bloco_final
}
