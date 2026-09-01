#!/usr/bin/env bash
# shellcheck shell=bash
#
# ============================================================
# lib/docker.sh
# Detecção e instalação do Docker.
#
# Depende de lib/ui.sh e de checks_os_release, de lib/checks.sh.
#
# Os comandos aqui são os que rodaram na VPS de teste em
# 2026-09-01 e estão registrados em "Comandos validados em VPS"
# no CLAUDE.md. Resultado daquela execução: Docker 29.7.2,
# Compose v5.5.0, serviço enabled e active, Swarm inactive.
#
# Vale para este arquivo a mesma regra de lib/ui.sh: depois do
# build.sh tudo divide o mesmo escopo global, então todo nome
# público leva prefixo docker_ ou PA_, e não há `return` fora de
# função.
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
# Detecção
# ------------------------------------------------------------

docker_binario_presente() {
	command -v docker >/dev/null 2>&1
}

# docker_daemon_ok
#
# Binário presente não significa daemon de pé. Um `docker` que
# existe mas cujo serviço está parado produz erro de socket que
# não diz nada para quem está começando.
docker_daemon_ok() {
	docker info >/dev/null 2>&1
}

# docker_presente
#
# O que a detecção de cenário considera "Docker presente":
# binário instalado e daemon respondendo.
docker_presente() {
	docker_binario_presente && docker_daemon_ok
}

docker_compose_presente() {
	docker compose version >/dev/null 2>&1
}

# docker_swarm_ativo
#
# Verdadeiro quando a máquina está em Swarm, como manager ou
# worker. O estado "pending" também conta: a máquina já saiu do
# Compose puro.
docker_swarm_ativo() {
	local estado
	estado="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || true)"

	[[ "$estado" == "active" || "$estado" == "pending" ]]
}

# docker_checar_swarm
#
# O instalador assume Compose puro. Suportar os dois modos dobra
# a superfície de bug: `depends_on` com `condition:
# service_healthy` é ignorado no Swarm, e rede overlay só aceita
# container externo se tiver sido criada como `attachable`.
docker_checar_swarm() {
	docker_binario_presente || return 0

	if docker_swarm_ativo; then
		ui_fatal \
			"Esta máquina está em modo Swarm." \
			"O instalador trabalha com Docker Compose puro e não se" \
			"adapta ao Swarm, onde depends_on com condition é ignorado" \
			"e rede overlay exige ser attachable." \
			"" \
			"Use uma VPS sem Swarm, ou instale o Mautic manualmente" \
			"como serviço do seu stack."
	fi
}

docker_versao() {
	docker version --format '{{.Server.Version}}' 2>/dev/null ||
		printf 'desconhecida\n'
}

docker_compose_versao() {
	docker compose version --short 2>/dev/null ||
		printf 'desconhecida\n'
}

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
