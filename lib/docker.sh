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
