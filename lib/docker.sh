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

# ------------------------------------------------------------
# Apoio ao modo de atualização
#
# Usado pelos dois instaladores, cada um para as suas stacks.
# ------------------------------------------------------------

# docker_versao_maior <a> <b>
#
# Verdadeiro quando a é mais nova que b. Compara como versão, e não
# como texto: 3.7.9 é menor que 3.7.16. Um "v" na frente é ignorado.
docker_versao_maior() {
	local uma="${1#v}" outra="${2#v}"
	[[ "$uma" != "$outra" ]] &&
		[[ "$(printf '%s\n%s\n' "$uma" "$outra" | sort -V | tail -n 1)" == "$uma" ]]
}

# docker_compose_desligado <pasta> <argumentos...>
#
# Roda `docker compose` da pasta numa sessão própria (setsid), sem
# saída na tela.
#
# Medido em 2026-10-27: a conexão SSH caiu no meio de um `up -d`, o
# comando morreu junto e a stack ficou pela metade, com container
# antigo em remoção e novo só criado. Numa sessão própria o comando
# termina mesmo que o terminal caia, e a execução seguinte encontra
# a troca feita.
docker_compose_desligado() {
	local pasta="$1"
	shift

	if command -v setsid >/dev/null 2>&1; then
		(cd "$pasta" && setsid --wait docker compose "$@" </dev/null >/dev/null 2>&1)
	else
		(cd "$pasta" && docker compose "$@" >/dev/null 2>&1)
	fi
}

# docker_imagem_do_servico <pasta> <servico>
#
# A imagem do container do serviço, parado ou não. Nada quando o
# container não existe.
docker_imagem_do_servico() {
	local id
	id="$(cd "$1" && docker compose ps -aq "$2" 2>/dev/null | head -n 1)" || true
	[[ -n "$id" ]] || return 0
	docker inspect --format '{{.Config.Image}}' "$id" 2>/dev/null || true
}

# docker_compose_registrar_hash <pasta>
#
# Guarda o sha256 do compose como o instalador o gravou. É o que
# permite ao modo de atualização dizer, antes de regravar o arquivo,
# se a pessoa mexeu nele: a alteração dela não vai junto, e ela
# precisa saber disso antes.
docker_compose_registrar_hash() {
	(cd "$1" && sha256sum docker-compose.yml >.compose.sha256) || true
}

# docker_compose_situacao <pasta>
#
# Ecoa um de: intacto, alterado, sem-registro. O último é o de
# instalação feita antes de este registro existir.
docker_compose_situacao() {
	if [[ ! -f "${1}/.compose.sha256" ]]; then
		printf 'sem-registro\n'
	elif (cd "$1" && sha256sum --status -c .compose.sha256) 2>/dev/null; then
		printf 'intacto\n'
	else
		printf 'alterado\n'
	fi
}
