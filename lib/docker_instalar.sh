#!/usr/bin/env bash
# shellcheck shell=bash
#
# ============================================================
# lib/docker_instalar.sh
# Instalação do Docker e criação de rede.
#
# Depende de lib/ui.sh, lib/docker.sh e de checks_os_release.
#
# Só entra no instalador de base. Um instalador de ferramenta
# detecta o Docker, mas nunca o instala: se estiver faltando, ele
# manda rodar a base e encerra. Assim a instalação do Docker
# existe em um lugar só, e os próximos instaladores a herdam em
# vez de recriá-la.
# ============================================================
# ------------------------------------------------------------
# Constantes
# ------------------------------------------------------------

# Pacotes do repositório oficial. O docker-compose-plugin é o que
# entrega `docker compose` como subcomando; o pacote antigo
# docker-compose, com hífen, é outro projeto e não serve.
PA_DOCKER_PACOTES=(
	docker-ce
	docker-ce-cli
	containerd.io
	docker-buildx-plugin
	docker-compose-plugin
)

PA_DOCKER_KEYRING="/etc/apt/keyrings/docker.asc"
PA_DOCKER_LISTA="/etc/apt/sources.list.d/docker.list"
PA_DOCKER_GPG_URL="https://download.docker.com/linux/ubuntu/gpg"
PA_DOCKER_REPO_URL="https://download.docker.com/linux/ubuntu"

# ------------------------------------------------------------
# Instalação
# ------------------------------------------------------------

# docker_instalar
#
# Método oficial de repositório, e não o script de conveniência
# do get.docker.com.
#
# Motivo, registrado no CLAUDE.md: o repositório é auditável,
# recebe atualização por `apt upgrade` junto com o resto do
# sistema, e não pede que a pessoa execute mais um script remoto
# logo depois de este instalador ter pedido para ela ler scripts
# antes de rodar.
docker_instalar() {
	ui_passo "Instalando o Docker"

	local codinome
	codinome="$(checks_os_release VERSION_CODENAME)"

	if [[ -z "$codinome" ]]; then
		ui_fatal \
			"Não consegui descobrir o codinome desta versão do Ubuntu." \
			"Sem ele não dá para montar a linha do repositório do Docker."
	fi

	export DEBIAN_FRONTEND=noninteractive

	ui_info "Atualizando a lista de pacotes"
	apt-get update -qq >/dev/null 2>&1 ||
		ui_fatal \
			"Falha ao atualizar a lista de pacotes." \
			"Confira a conexão da VPS e rode: apt-get update"

	ui_info "Instalando pré-requisitos"
	apt-get install -y -qq ca-certificates curl >/dev/null 2>&1 ||
		ui_fatal "Falha ao instalar ca-certificates e curl."

	ui_info "Adicionando a chave e o repositório oficiais do Docker"
	install -m 0755 -d /etc/apt/keyrings

	curl -fsSL "$PA_DOCKER_GPG_URL" -o "$PA_DOCKER_KEYRING" ||
		ui_fatal \
			"Falha ao baixar a chave do repositório do Docker." \
			"Origem: ${PA_DOCKER_GPG_URL}"

	chmod a+r "$PA_DOCKER_KEYRING"

	printf 'deb [arch=%s signed-by=%s] %s %s stable\n' \
		"$(dpkg --print-architecture)" \
		"$PA_DOCKER_KEYRING" \
		"$PA_DOCKER_REPO_URL" \
		"$codinome" \
		>"$PA_DOCKER_LISTA"

	ui_info "Atualizando a lista com o repositório do Docker"
	apt-get update -qq >/dev/null 2>&1 ||
		ui_fatal \
			"Falha ao ler o repositório do Docker." \
			"Verifique ${PA_DOCKER_LISTA}"

	ui_info "Instalando Docker e o plugin do Compose"
	apt-get install -y -qq "${PA_DOCKER_PACOTES[@]}" >/dev/null 2>&1 ||
		ui_fatal \
			"Falha ao instalar os pacotes do Docker." \
			"Rode à mão para ver o erro:" \
			"" \
			"    apt-get install ${PA_DOCKER_PACOTES[*]}"

	# O pacote docker-ce já cria e habilita o serviço; não é
	# preciso systemctl enable --now. Confirmado no teste.
	ui_aguardar_ate "Aguardando o daemon do Docker" 60 docker_daemon_ok ||
		ui_fatal \
			"O Docker foi instalado mas o daemon não respondeu." \
			"Diagnostique com:" \
			"" \
			"    systemctl status docker" \
			"    journalctl -u docker -n 50"

	ui_ok "Docker $(docker_versao), Compose $(docker_compose_versao)"
}

# docker_garantir
#
# Ponto de entrada da etapa 7 para o Docker. Idempotente: se já
# estiver tudo lá, não mexe em nada e diz o que encontrou.
#
# Cobre também o cenário 1.5, em que o Docker existe mas o plugin
# do Compose não — caso de quem instalou pelo pacote da
# distribuição em vez do repositório oficial.
docker_garantir() {
	if docker_presente && docker_compose_presente; then
		ui_ok "Docker $(docker_versao) e Compose $(docker_compose_versao) já instalados"
		return 0
	fi

	if docker_binario_presente && ! docker_daemon_ok; then
		ui_fatal \
			"O Docker está instalado mas o daemon não responde." \
			"O instalador não mexe em serviço que já existe nesta máquina." \
			"Suba o daemon e rode de novo:" \
			"" \
			"    systemctl start docker"
	fi

	if docker_presente && ! docker_compose_presente; then
		ui_aviso "Docker presente, mas sem o plugin do Compose."
		ui_detalhe "Instalando o repositório oficial para obter o plugin."
	fi

	docker_instalar
}

# ------------------------------------------------------------
# Rede
# ------------------------------------------------------------

docker_rede_existe() {
	local nome="$1"

	docker network inspect "$nome" >/dev/null 2>&1
}

# docker_criar_rede <nome>
#
# Operação aditiva e idempotente, das permitidas pela regra de
# nada destrutivo. Rede que já existe é reaproveitada como está:
# recriar derrubaria os containers de outra pessoa que já estão
# nela.
docker_criar_rede() {
	local nome="$1"

	if docker_rede_existe "$nome"; then
		ui_ok "Rede ${nome} já existe"
		return 0
	fi

	if ! docker network create "$nome" >/dev/null 2>&1; then
		ui_fatal \
			"Falha ao criar a rede ${nome}." \
			"Rode à mão para ver o erro:" \
			"" \
			"    docker network create ${nome}"
	fi

	ui_ok "Rede ${nome} criada"
}
