#!/usr/bin/env bash
# shellcheck shell=bash
#
# ============================================================
# lib/traefik_instalar.sh
# Instalação do Traefik.
#
# Depende de lib/ui.sh, lib/portas.sh e lib/docker_instalar.sh.
#
# Só entra no instalador de base, pelo mesmo motivo do
# docker_instalar.sh: o proxy é infraestrutura compartilhada, e
# quem instala infraestrutura é a base. O instalador de ferramenta
# só detecta, para descobrir os nomes de rede, entrypoint e
# certresolver que precisa citar nos labels.
# ============================================================
# ------------------------------------------------------------
# Constantes
# ------------------------------------------------------------

# Versão fixa da linha v3, nunca `latest`. Conferida na API do
# Docker Hub em 2026-09-01 e validada em VPS.
PA_TRAEFIK_VERSAO="v3.7.12"

PA_TRAEFIK_DIR="/opt/playahead/traefik"
PA_TRAEFIK_REDE="traefik_public"

# ------------------------------------------------------------
# Instalação
# ------------------------------------------------------------

# traefik_gerar_compose <caminho> <email_acme>
#
# Decisões que este compose carrega, e o motivo de cada uma:
#
#   exposedByDefault=false  sem isso todo container da máquina
#                           vira roteador por acidente
#   redirect no entrypoint  um middleware precisaria ser citado
#                           por cada roteador; no entrypoint vale
#                           para tudo e o .env do Mautic não
#                           precisa saber que existe
#   httpchallenge           é o desafio que funciona quando o DNS
#                           acabou de ser apontado e ainda não há
#                           certificado nenhum
#   socket :ro              o Traefik só precisa ler
traefik_gerar_compose() {
	local caminho="$1"

	cat >"$caminho" <<COMPOSE
services:
  traefik:
    image: traefik:${PA_TRAEFIK_VERSAO}
    restart: unless-stopped
    command:
      - --providers.docker=true
      - --providers.docker.exposedByDefault=false
      - --entrypoints.web.address=:80
      - --entrypoints.web.http.redirections.entrypoint.to=websecure
      - --entrypoints.web.http.redirections.entrypoint.scheme=https
      - --entrypoints.websecure.address=:443
      - --certificatesresolvers.letsencrypt.acme.email=\${ACME_EMAIL}
      - --certificatesresolvers.letsencrypt.acme.storage=/letsencrypt/acme.json
      - --certificatesresolvers.letsencrypt.acme.httpchallenge=true
      - --certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=web
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - traefik_letsencrypt:/letsencrypt
    networks:
      - ${PA_TRAEFIK_REDE}

volumes:
  traefik_letsencrypt:
    name: playahead_traefik_letsencrypt

networks:
  ${PA_TRAEFIK_REDE}:
    external: true
    name: ${PA_TRAEFIK_REDE}
COMPOSE
}

# shellcheck disable=SC2034
# traefik_instalar <email_acme>
#
# Idempotente pela regra de nada destrutivo: encontrando um
# compose nosso já no lugar, não sobrescreve. O e-mail do ACME
# vive no .env, com umask 077.
traefik_instalar() {
	local email_acme="$1"

	ui_passo "Instalando o Traefik ${PA_TRAEFIK_VERSAO}"

	docker_criar_rede "$PA_TRAEFIK_REDE"

	mkdir -p "$PA_TRAEFIK_DIR"

	local compose="${PA_TRAEFIK_DIR}/docker-compose.yml"
	local env_file="${PA_TRAEFIK_DIR}/.env"

	if [[ -f "$compose" ]]; then
		ui_ok "Compose do Traefik já existe em ${PA_TRAEFIK_DIR}"
		ui_detalhe "Não sobrescrito, conforme a regra de nada destrutivo."
	else
		traefik_gerar_compose "$compose"
		ui_ok "Compose gravado em ${compose}"
	fi

	if [[ -f "$env_file" ]]; then
		ui_ok ".env do Traefik já existe"
	else
		local mascara_antiga
		mascara_antiga="$(umask)"
		umask 077
		printf 'ACME_EMAIL=%s\n' "$email_acme" >"$env_file"
		umask "$mascara_antiga"
		ui_ok ".env gravado, com o e-mail do Let's Encrypt"
	fi

	ui_info "Subindo o Traefik"
	if ! (cd "$PA_TRAEFIK_DIR" && docker compose up -d >/dev/null 2>&1); then
		ui_fatal \
			"Falha ao subir o Traefik." \
			"Rode à mão para ver o erro:" \
			"" \
			"    cd ${PA_TRAEFIK_DIR} && docker compose up -d"
	fi

	ui_aguardar_ate "Aguardando o Traefik ocupar as portas 80 e 443" 90 \
		traefik_portas_ocupadas ||
		ui_fatal \
			"O Traefik subiu mas não está ouvindo em 80 e 443." \
			"Veja o log:" \
			"" \
			"    cd ${PA_TRAEFIK_DIR} && docker compose logs traefik"

	ui_ok "Traefik ${PA_TRAEFIK_VERSAO} no ar"

	# As seis abaixo são declaradas em lib/traefik.sh e lidas por
	# traefik_mostrar_deteccao. A diretiva está no topo da função,
	# porque o shellcheck não enxerga uso entre arquivos.
	PA_TRAEFIK_NETWORK="$PA_TRAEFIK_REDE"
	PA_TRAEFIK_NETWORK_ORIGEM="instalado por este script"
	PA_TRAEFIK_ENTRYPOINT="websecure"
	PA_TRAEFIK_ENTRYPOINT_ORIGEM="instalado por este script"
	PA_TRAEFIK_CERTRESOLVER="letsencrypt"
	PA_TRAEFIK_CERTRESOLVER_ORIGEM="instalado por este script"
}

# traefik_portas_ocupadas
#
# Usa a cadeia de lib/portas.sh, para não reintroduzir a
# dependência de `ss` que aquele módulo já resolveu.
traefik_portas_ocupadas() {
	local ferramenta
	ferramenta="$(portas_ferramenta)"

	[[ -n "$ferramenta" ]] || return 1

	portas_ocupada 80 "$ferramenta" &&
		portas_ocupada 443 "$ferramenta"
}

# ============================================================
