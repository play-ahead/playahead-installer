#!/usr/bin/env bash
# shellcheck shell=bash
#
# ============================================================
# lib/portainer.sh
# Instalação opcional do Portainer, sempre por último.
#
# Depende de lib/ui.sh, lib/checks.sh, lib/docker.sh e das
# variáveis de rede preenchidas por lib/traefik.sh.
#
# REGRA QUE VALE PARA O ARQUIVO TODO: nenhuma função aqui chama
# ui_fatal. O Portainer roda depois de o Mautic estar de pé, e a
# decisão de projeto é que uma falha aqui seja aviso, não
# desastre — a pessoa termina com o Mautic funcionando de
# qualquer jeito. Toda função devolve status; quem decide o que
# fazer é o main.sh.
#
# NÃO VALIDADO EM VPS. O módulo foi escrito depois de a máquina
# de teste ser destruída. A instalação do Mautic e a detecção do
# Traefik têm teste; isto ainda não.
# ============================================================

# ------------------------------------------------------------
# Constantes
# ------------------------------------------------------------

# Versão fixa, nunca `latest`, pela mesma razão do Traefik.
#
# 2.45.0 é a LTS em 2026-09-12. Conferido comparando o digest da
# tag `lts` com o da tag numerada, e não assumido pelo número:
# a linha 2.39.x recebe patches e parece LTS, mas o digest da
# `lts` bate com a 2.45.0.
PA_PORTAINER_VERSAO="2.45.0"

PA_PORTAINER_DIR="/opt/playahead/portainer"

# Preenchida na instalação, lida pelo bloco final.
PA_PORTAINER_INSTALADO=0

# ------------------------------------------------------------
# Detecção
# ------------------------------------------------------------

# portainer_ja_existe
#
# Container em execução cuja imagem casa com "portainer".
# Encontrando um, não mexe: pode ser o Portainer de outra pessoa,
# gerenciando containers que não são nossos.
portainer_ja_existe() {
	docker ps --format '{{.Image}}' 2>/dev/null |
		grep -qi 'portainer'
}

# ------------------------------------------------------------
# Compose
# ------------------------------------------------------------

# portainer_gerar_compose <caminho>
#
# O socket do Docker vai montado para LEITURA E ESCRITA, ao
# contrário do Traefik, que recebe `:ro`. Não há como contornar:
# o Portainer existe para criar, parar e remover containers.
#
# A consequência precisa ficar dita em voz alta, porque não é
# óbvia para quem está começando: quem entra no Portainer tem,
# na prática, root nesta máquina. É por isso que a senha de
# admin precisa ser definida na primeira visita, e é por isso
# que o Portainer não entra no fluxo principal do instalador.
portainer_gerar_compose() {
	local caminho="$1"

	local rede="${PA_TRAEFIK_NETWORK:-traefik_public}"
	local entrypoint="${PA_TRAEFIK_ENTRYPOINT:-websecure}"

	{
		cat <<COMPOSE
# ============================================================
# PLAY AHEAD - Portainer
# Gerado pelo instalador. Versão fixa: ${PA_PORTAINER_VERSAO}
#
# ATENÇÃO: este container monta o socket do Docker com permissão
# de escrita. Quem tem acesso ao Portainer tem controle total
# desta máquina. Use senha forte e não exponha sem necessidade.
# ============================================================

services:

  portainer:
    image: portainer/portainer-ce:${PA_PORTAINER_VERSAO}
    restart: unless-stopped

    command: -H unix:///var/run/docker.sock

    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - playahead_portainer_data:/data

    networks:
      - proxy

    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.playahead-portainer.rule=Host(\`${PA_PORTAINER_DOMINIO}\`)"
      - "traefik.http.routers.playahead-portainer.entrypoints=${entrypoint}"
      - "traefik.http.routers.playahead-portainer.tls=true"
COMPOSE

		# O certresolver é omitido quando não existe, e não
		# preenchido com palpite. Mesma regra do Mautic: quem
		# termina TLS no Cloudflare não tem resolver, e um nome
		# inventado produz roteador que não sobe.
		if [[ -n "${PA_TRAEFIK_CERTRESOLVER:-}" ]]; then
			printf '      - "traefik.http.routers.playahead-portainer.tls.certresolver=%s"\n' \
				"$PA_TRAEFIK_CERTRESOLVER"
		fi

		cat <<COMPOSE
      - "traefik.http.services.playahead-portainer.loadbalancer.server.port=9000"
      - "traefik.docker.network=${rede}"

volumes:
  playahead_portainer_data:
    name: playahead_portainer_data

networks:
  proxy:
    external: true
    name: ${rede}
COMPOSE
	} >"$caminho"
}

# ------------------------------------------------------------
# Instalação
# ------------------------------------------------------------

# portainer_instalar <dominio>
#
# Devolve 0 em sucesso. Qualquer falha devolve não-zero, com
# aviso na tela, e deixa o main.sh seguir para o bloco final.
portainer_instalar() {
	PA_PORTAINER_DOMINIO="$1"

	ui_secao "Portainer"

	if portainer_ja_existe; then
		ui_aviso "Já existe um Portainer em execução nesta máquina."
		ui_detalhe "Não vou mexer nele: pode estar gerenciando containers"
		ui_detalhe "que não são desta instalação."
		return 0
	fi

	# DNS do subdomínio do Portainer. Aqui a checagem AVISA em vez
	# de abortar, ao contrário do domínio do Mautic: o Mautic já
	# está no ar, e derrubar a execução por causa de um DNS
	# opcional seria trocar o certo pelo duvidoso.
	if [[ "$PA_SKIP_DNS" -ne 1 ]] && [[ -n "$PA_IP_PUBLICO" ]]; then
		local resolvidos=()
		mapfile -t resolvidos < <(
			getent ahostsv4 "$PA_PORTAINER_DOMINIO" 2>/dev/null |
				awk '{print $1}' | sort -u
		)

		if [[ "${#resolvidos[@]}" -eq 0 ]]; then
			ui_aviso "${PA_PORTAINER_DOMINIO} ainda não resolve para nenhum IP."
			ui_detalhe "O certificado não será emitido enquanto o DNS não"
			ui_detalhe "apontar para ${PA_IP_PUBLICO}."
			ui_detalhe "O Portainer vai subir, mas o domínio só abre depois."
		elif [[ " ${resolvidos[*]} " != *" ${PA_IP_PUBLICO} "* ]] &&
			! checks_ip_em_cdn "${resolvidos[0]}"; then
			ui_aviso "${PA_PORTAINER_DOMINIO} aponta para outro servidor."
			ui_detalhe "resolve para: ${resolvidos[*]}"
			ui_detalhe "esta VPS é:   ${PA_IP_PUBLICO}"
			ui_detalhe "O Portainer vai subir, mas o domínio não vai abrir."
		fi
	fi

	mkdir -p "$PA_PORTAINER_DIR"

	local compose="${PA_PORTAINER_DIR}/docker-compose.yml"

	if [[ -f "$compose" ]]; then
		ui_ok "Compose do Portainer já existe; mantido como está"
	else
		portainer_gerar_compose "$compose"
		ui_ok "Compose gravado em ${compose}"
	fi

	ui_info "Subindo o Portainer ${PA_PORTAINER_VERSAO}"

	if ! (cd "$PA_PORTAINER_DIR" && docker compose up -d >/dev/null 2>&1); then
		ui_aviso "Falha ao subir o Portainer."
		ui_detalhe "O Mautic não foi afetado e segue no ar."
		ui_detalhe "Para ver o erro:"
		ui_detalhe "cd ${PA_PORTAINER_DIR} && docker compose up -d"
		return 1
	fi

	if ! ui_aguardar_ate "Aguardando o Portainer responder" 90 \
		portainer_respondendo; then
		ui_aviso "O Portainer subiu mas não respondeu no tempo esperado."
		ui_detalhe "Veja: cd ${PA_PORTAINER_DIR} && docker compose logs"
		return 1
	fi

	PA_PORTAINER_INSTALADO=1
	ui_ok "Portainer ${PA_PORTAINER_VERSAO} no ar"

	portainer_verificar_roteamento "$PA_PORTAINER_DOMINIO" || true

	return 0
}

# portainer_respondendo
#
# Pergunta ao próprio container, sem depender do Traefik nem do
# DNS. A imagem do Portainer não traz curl nem wget, então o
# teste é feito de fora, pela rede do Docker: se o container está
# em execução e não reiniciando, o serviço subiu.
portainer_respondendo() {
	local id
	id="$(cd "$PA_PORTAINER_DIR" && docker compose ps -q portainer 2>/dev/null)"
	[[ -n "$id" ]] || return 1

	local estado
	estado="$(docker inspect --format '{{.State.Status}}' "$id" 2>/dev/null)"

	[[ "$estado" == "running" ]]
}

# portainer_verificar_roteamento <dominio>
#
# Mesma verificação anti-404 do Mautic, mas sempre como aviso.
portainer_verificar_roteamento() {
	local dominio="$1"

	local codigo
	codigo="$(curl -sk -o /dev/null -w '%{http_code}' \
		--max-time 15 "https://${dominio}/" 2>/dev/null || true)"

	case "$codigo" in
		200 | 302 | 301 | 307)
			ui_ok "O domínio do Portainer responde ${codigo}"
			return 0
			;;
		404)
			ui_aviso "O Traefik respondeu, mas não roteou para o Portainer."
			ui_detalhe "Confira os nomes em ${PA_PORTAINER_DIR}/docker-compose.yml"
			;;
		*)
			ui_aviso "O domínio do Portainer respondeu ${codigo:-nada}."
			ui_detalhe "Pode ser propagação de DNS ou emissão de certificado."
			;;
	esac

	return 1
}

# ------------------------------------------------------------
# Credenciais e primeira visita
# ------------------------------------------------------------

# portainer_anexar_credenciais <arquivo>
#
# Acrescenta o bloco do Portainer no mesmo credenciais.txt do
# Mautic, em vez de criar um segundo arquivo. Um arquivo só, com
# tudo da instalação, é mais fácil de achar meses depois do que
# dois arquivos em pastas diferentes.
portainer_anexar_credenciais() {
	local arquivo="$1"

	[[ "$PA_PORTAINER_INSTALADO" -eq 1 ]] || return 0
	[[ -f "$arquivo" ]] || return 0

	{
		printf '\n'
		printf 'PORTAINER\n'
		printf '  URL:   https://%s\n' "$PA_PORTAINER_DOMINIO"
		printf '  senha: definida por você na primeira visita\n'
		printf '  pasta: %s\n' "$PA_PORTAINER_DIR"
	} >>"$arquivo"

	chmod 600 "$arquivo"
}

# portainer_aviso_primeira_visita
#
# O Portainer fecha a criação do usuário administrador se ninguém
# a fizer poucos minutos depois de o container subir, e então só
# volta a aceitar com um restart do container. Numa instalação
# que a pessoa deixa rodando e vai tomar café, isso vira um
# "não funcionou" que não tem nada de erro.
#
# Por isso o aviso é explícito e traz o comando de recuperação.
portainer_aviso_primeira_visita() {
	[[ "$PA_PORTAINER_INSTALADO" -eq 1 ]] || return 0

	ui_vazio
	ui_info "PORTAINER: abra agora e defina a senha."
	ui_detalhe "https://${PA_PORTAINER_DOMINIO}"
	ui_vazio
	ui_info "O Portainer encerra a criação do administrador poucos"
	ui_info "minutos depois de subir. Passando desse prazo, ele só"
	ui_info "volta a aceitar com um restart:"
	ui_detalhe "cd ${PA_PORTAINER_DIR} && docker compose restart"
	ui_vazio
	ui_info "Quem entra no Portainer controla todos os containers"
	ui_info "desta máquina. Use uma senha forte."
}
