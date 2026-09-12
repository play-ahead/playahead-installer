#!/usr/bin/env bash
# shellcheck shell=bash
#
# ============================================================
# lib/cenario.sh
# Classificação do estado da máquina.
#
# Depende de lib/ui.sh, lib/docker.sh e lib/traefik.sh.
#
# Compartilhado pelos dois instaladores, e é a razão de existir
# como arquivo próprio: a tabela de cinco estados é o trecho que
# mais sofreria se fosse duplicada nos dois orquestradores.
#
# Este arquivo **classifica, não decide**. Ele diz em que estado a
# máquina está; o que fazer com isso é política de cada
# orquestrador. Por isso a checagem de portas 80 e 443 não está
# aqui: ela só importa para quem vai subir um proxy, e isso é
# assunto da base.
# ============================================================

# ------------------------------------------------------------
# Estado
# ------------------------------------------------------------

# Preenchidas por cenario_classificar. Não há variável com o
# "número do cenário": ninguém a lia, e estes três sinalizadores
# carregam a mesma informação sem precisar de tradução.
PA_TEM_DOCKER=0
PA_TEM_COMPOSE=0
PA_TEM_TRAEFIK=0

# ------------------------------------------------------------
# Classificação
# ------------------------------------------------------------

# cenario_classificar
#
# A tabela de estados do CLAUDE.md, reduzida ao que dá para
# afirmar só olhando Docker e Traefik:
#
#   nada instalado                    -> cenário 1
#   Docker presente, sem proxy        -> cenário 1.5
#   Docker e Traefik presentes        -> cenário 2
#
# O nome do cenário fica na mensagem de tela de cada orquestrador,
# em palavras, e não numa variável: era só rótulo.
#
# As duas linhas que abortam na tabela — portas ocupadas sem
# proxy — dependem do estado das portas, e quem as trata é o
# instalador de base, porque só ele tem motivo para querer as
# portas livres.
#
# Swarm ativo para aqui, em qualquer estado.
cenario_classificar() {
	docker_checar_swarm

	docker_presente && PA_TEM_DOCKER=1
	[[ "$PA_TEM_DOCKER" -eq 1 ]] && docker_compose_presente && PA_TEM_COMPOSE=1

	if [[ "$PA_TEM_DOCKER" -eq 1 ]] && traefik_detectar; then
		PA_TEM_TRAEFIK=1
	fi

}

# cenario_base_completa
#
# Verdadeiro quando a base já está inteira: Docker, plugin do
# Compose e um Traefik em execução.
#
# É o que um instalador de ferramenta precisa saber. Para ele não
# existem cinco estados, existem dois: a base está pronta, ou
# falta rodar a base.
cenario_base_completa() {
	[[ "$PA_TEM_DOCKER" -eq 1 ]] &&
		[[ "$PA_TEM_COMPOSE" -eq 1 ]] &&
		[[ "$PA_TEM_TRAEFIK" -eq 1 ]]
}

# cenario_faltando
#
# Ecoa, em texto, o que falta da base. Serve para a mensagem que
# manda a pessoa rodar o instalador de base: dizer "falta a base"
# é menos útil que dizer o que exatamente não está lá.
cenario_faltando() {
	local faltando=()

	[[ "$PA_TEM_DOCKER" -eq 1 ]] || faltando+=("Docker")
	[[ "$PA_TEM_COMPOSE" -eq 1 ]] || faltando+=("plugin do Docker Compose")
	[[ "$PA_TEM_TRAEFIK" -eq 1 ]] || faltando+=("Traefik")

	if [[ "${#faltando[@]}" -eq 0 ]]; then
		return 1
	fi

	local texto
	texto="$(printf '%s, ' "${faltando[@]}")"
	printf '%s\n' "${texto%, }"
}
