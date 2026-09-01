#!/usr/bin/env bash
# shellcheck shell=bash
#
# ============================================================
# lib/traefik.sh
# Instalação (cenários 1 e 1.5) e detecção (cenário 2).
#
# Depende de lib/ui.sh e lib/docker.sh.
#
# ATENÇÃO AO GRAU DE VALIDAÇÃO. As duas metades deste arquivo
# não têm a mesma maturidade:
#
#   - A instalação rodou na VPS de teste em 2026-09-01, com
#     Traefik v3.7.12 sobre Docker 29.7.2, emitiu certificado e
#     roteou o Mautic. Está em "Comandos validados em VPS" no
#     CLAUDE.md.
#   - A detecção do cenário 2 segue a precedência decidida no
#     CLAUDE.md mas AINDA NÃO foi testada contra um Traefik de
#     terceiro. Precisa de uma VPS com proxy alheio antes de ir
#     para o vídeo.
#
# É a detecção que evita o modo de falha mais caro do projeto:
# cravar os nomes padrão faz o container subir, o Mautic
# funcionar e o domínio devolver 404 sem nenhuma mensagem.
# ============================================================

# ------------------------------------------------------------
# Constantes
# ------------------------------------------------------------

# Versão fixa da linha v3, nunca `latest`. Conferida na API do
# Docker Hub em 2026-09-01 e validada em VPS.
PA_TRAEFIK_VERSAO="v3.7.12"

PA_TRAEFIK_DIR="/opt/playahead/traefik"
PA_TRAEFIK_REDE="traefik_public"

# Redes que nunca são a rede do proxy.
PA_TRAEFIK_REDES_IGNORADAS=("bridge" "host" "none")

# Preenchidas pela detecção. Cada valor anda junto com a origem,
# porque a tela de confirmação precisa dizer de onde tirou cada
# coisa — "detectado" sem procedência não ajuda a decidir.
PA_TRAEFIK_CONTAINER=""
PA_TRAEFIK_ENTRYPOINT=""
PA_TRAEFIK_ENTRYPOINT_ORIGEM=""
PA_TRAEFIK_CERTRESOLVER=""
PA_TRAEFIK_CERTRESOLVER_ORIGEM=""
PA_TRAEFIK_NETWORK=""
PA_TRAEFIK_NETWORK_ORIGEM=""
PA_TRAEFIK_HOST_MODE=0

# ============================================================
# PARTE 1 — INSTALAÇÃO (cenários 1 e 1.5)
# ============================================================

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

	PA_TRAEFIK_NETWORK="$PA_TRAEFIK_REDE"
	PA_TRAEFIK_NETWORK_ORIGEM="instalado por este script"
	PA_TRAEFIK_ENTRYPOINT="websecure"
	PA_TRAEFIK_ENTRYPOINT_ORIGEM="instalado por este script"
	PA_TRAEFIK_CERTRESOLVER="letsencrypt"
	PA_TRAEFIK_CERTRESOLVER_ORIGEM="instalado por este script"
}

# traefik_portas_ocupadas
#
# Usa a mesma cadeia de ferramentas de checks.sh, para não
# reintroduzir a dependência de `ss` que aquele módulo já
# resolveu.
traefik_portas_ocupadas() {
	local ferramenta
	ferramenta="$(checks_ferramenta_de_porta)"

	[[ -n "$ferramenta" ]] || return 1

	checks_porta_ocupada 80 "$ferramenta" &&
		checks_porta_ocupada 443 "$ferramenta"
}

# ============================================================
# PARTE 2 — DETECÇÃO (cenário 2)
# ============================================================

# traefik_listar_containers
#
# Identificação por imagem, como decidido: container em execução
# cuja imagem casa com "traefik".
traefik_listar_containers() {
	docker ps --format '{{.Names}}\t{{.Image}}' 2>/dev/null |
		awk -F'\t' 'tolower($2) ~ /traefik/ {print $1}'
}

# traefik_detectar_container
#
# Havendo mais de um, pergunta. Havendo zero mas alguém segurando
# o 443, mostra quem é e para — sem inventar.
traefik_detectar_container() {
	local encontrados=()
	mapfile -t encontrados < <(traefik_listar_containers)

	if [[ "${#encontrados[@]}" -eq 0 ]]; then
		return 1
	fi

	ui_escolher PA_TRAEFIK_CONTAINER \
		"Mais de um Traefik em execução. Qual é o proxy desta máquina?" \
		"${encontrados[@]}"

	return 0
}

# traefik_inspect <container> <template_go>
traefik_inspect() {
	local container="$1"
	local template="$2"

	docker inspect --format "$template" "$container" 2>/dev/null || true
}

# traefik_argumentos <container>
#
# Junta Entrypoint, Cmd e Args numa linha só. Instaladores
# diferentes espalham as flags entre os três campos, e procurar
# em apenas um deles perde configuração.
traefik_argumentos() {
	local container="$1"

	traefik_inspect "$container" \
		'{{range .Config.Entrypoint}}{{.}} {{end}}{{range .Config.Cmd}}{{.}} {{end}}{{range .Args}}{{.}} {{end}}'
}

# traefik_ambiente <container>
traefik_ambiente() {
	local container="$1"

	traefik_inspect "$container" '{{range .Config.Env}}{{.}}
{{end}}'
}

# traefik_labels <container>
#
# Os $k e $v abaixo são do template do Go, não do shell: aspas
# simples são o que se quer aqui.
# shellcheck disable=SC2016
traefik_labels() {
	local container="$1"

	traefik_inspect "$container" '{{range $k, $v := .Config.Labels}}{{$k}}={{$v}}
{{end}}'
}

# traefik_config_estatica <container>
#
# Lê o arquivo de configuração de dentro do container.
#
# É a fonte que uma detecção ingênua ignora, e é justamente a que
# os instaladores populares mais usam. Quem só olha flags de CLI
# passa direto por ela e conclui que não há certresolver nenhum.
traefik_config_estatica() {
	local container="$1"
	local caminho

	for caminho in \
		/etc/traefik/traefik.yml \
		/etc/traefik/traefik.yaml \
		/traefik.yml \
		/traefik.yaml \
		/config/traefik.yml \
		/config/traefik.yaml; do
		local conteudo
		conteudo="$(docker exec "$container" cat "$caminho" 2>/dev/null || true)"

		if [[ -n "$conteudo" ]]; then
			printf '%s\n' "$conteudo"
			return 0
		fi
	done

	return 1
}

# ------------------------------------------------------------
# Entrypoint
# ------------------------------------------------------------

# traefik_detectar_entrypoint <container>
#
# Procura o entrypoint ligado à porta 443, que é o que o label do
# Mautic precisa citar. O nome fica entre "entrypoints." e
# ".address".
traefik_detectar_entrypoint() {
	local container="$1"
	local nome=""

	nome="$(traefik_argumentos "$container" |
		grep -oE -- '--entry[pP]oints\.[A-Za-z0-9_-]+\.address=:443' |
		head -1 |
		sed -E 's/.*entry[pP]oints\.([A-Za-z0-9_-]+)\.address.*/\1/')"

	if [[ -n "$nome" ]]; then
		PA_TRAEFIK_ENTRYPOINT="$nome"
		PA_TRAEFIK_ENTRYPOINT_ORIGEM="flags de linha de comando"
		return 0
	fi

	# O Traefik aceita configuração por variável de ambiente:
	# TRAEFIK_ENTRYPOINTS_<NOME>_ADDRESS=:443
	nome="$(traefik_ambiente "$container" |
		grep -oE '^TRAEFIK_ENTRYPOINTS_[A-Z0-9_]+_ADDRESS=:443' |
		head -1 |
		sed -E 's/^TRAEFIK_ENTRYPOINTS_(.+)_ADDRESS=.*/\1/')"

	if [[ -n "$nome" ]]; then
		PA_TRAEFIK_ENTRYPOINT="${nome,,}"
		PA_TRAEFIK_ENTRYPOINT_ORIGEM="variável de ambiente do container"
		return 0
	fi

	# Labels do próprio container. Muita instalação expõe o
	# dashboard do Traefik por um roteador no próprio container, e
	# esse roteador cita o entrypoint HTTPS.
	#
	# Heurística: o label pode listar vários separados por vírgula,
	# como "web,websecure", e daí não dá para saber qual é o 443.
	# Fica o último, que pela convenção é o seguro. As fontes
	# acima, que casam com address=:443, são exatas e vêm antes.
	nome="$(traefik_labels "$container" |
		grep -oE '^traefik\.http\.routers\.[A-Za-z0-9_-]+\.entry[pP]oints=.+' |
		head -1 |
		sed -E 's/.*entry[pP]oints=//' |
		tr ',' '\n' |
		tail -1 |
		tr -d '[:space:]')"

	if [[ -n "$nome" ]]; then
		PA_TRAEFIK_ENTRYPOINT="$nome"
		PA_TRAEFIK_ENTRYPOINT_ORIGEM="label do container do Traefik"
		return 0
	fi

	# Arquivo estático: bloco entryPoints com address ":443".
	local config
	if config="$(traefik_config_estatica "$container")"; then
		nome="$(printf '%s\n' "$config" |
			awk '
				/^[[:space:]]*entry[pP]oints:/ { dentro = 1; next }
				dentro && /^[^[:space:]]/      { dentro = 0 }
				dentro && /^[[:space:]]{2}[A-Za-z0-9_-]+:/ {
					gsub(/[[:space:]:]/, "", $0); atual = $0
				}
				dentro && /address:/ && /:443/ { print atual; exit }
			')"

		if [[ -n "$nome" ]]; then
			PA_TRAEFIK_ENTRYPOINT="$nome"
			PA_TRAEFIK_ENTRYPOINT_ORIGEM="arquivo estático dentro do container"
			return 0
		fi
	fi

	return 1
}

# ------------------------------------------------------------
# Certresolver
# ------------------------------------------------------------

# traefik_detectar_certresolver <container>
#
# Ausência é resposta legítima, não falha.
#
# Quem termina TLS no Cloudflare não tem certresolver nenhum, e
# preencher "letsencrypt" no chute produz um roteador que não
# sobe. É o outro lado do falso positivo de DNS tratado em
# checks.sh, e os dois precisam ser coerentes.
traefik_detectar_certresolver() {
	local container="$1"
	local nome=""

	nome="$(traefik_argumentos "$container" |
		grep -oE -- '--certificates[rR]esolvers\.[A-Za-z0-9_-]+\.acme' |
		head -1 |
		sed -E 's/.*certificates[rR]esolvers\.([A-Za-z0-9_-]+)\.acme.*/\1/')"

	if [[ -n "$nome" ]]; then
		PA_TRAEFIK_CERTRESOLVER="$nome"
		PA_TRAEFIK_CERTRESOLVER_ORIGEM="flags de linha de comando"
		return 0
	fi

	nome="$(traefik_ambiente "$container" |
		grep -oE '^TRAEFIK_CERTIFICATESRESOLVERS_[A-Z0-9_]+_ACME' |
		head -1 |
		sed -E 's/^TRAEFIK_CERTIFICATESRESOLVERS_(.+)_ACME.*/\1/')"

	if [[ -n "$nome" ]]; then
		PA_TRAEFIK_CERTRESOLVER="${nome,,}"
		PA_TRAEFIK_CERTRESOLVER_ORIGEM="variável de ambiente do container"
		return 0
	fi

	# Labels do próprio container, pelo mesmo motivo do entrypoint:
	# o roteador do dashboard costuma citar o certresolver real.
	nome="$(traefik_labels "$container" |
		grep -oE '^traefik\.http\.routers\.[A-Za-z0-9_-]+\.tls\.certresolver=[A-Za-z0-9_-]+' |
		head -1 |
		sed -E 's/.*certresolver=//')"

	if [[ -n "$nome" ]]; then
		PA_TRAEFIK_CERTRESOLVER="$nome"
		PA_TRAEFIK_CERTRESOLVER_ORIGEM="label do container do Traefik"
		return 0
	fi

	local config
	if config="$(traefik_config_estatica "$container")"; then
		nome="$(printf '%s\n' "$config" |
			awk '
				/^[[:space:]]*certificates[rR]esolvers:/ { dentro = 1; next }
				dentro && /^[^[:space:]]/                { dentro = 0 }
				dentro && /^[[:space:]]{2}[A-Za-z0-9_-]+:/ {
					gsub(/[[:space:]:]/, "", $0); print $0; exit
				}
			')"

		if [[ -n "$nome" ]]; then
			PA_TRAEFIK_CERTRESOLVER="$nome"
			PA_TRAEFIK_CERTRESOLVER_ORIGEM="arquivo estático dentro do container"
			return 0
		fi
	fi

	PA_TRAEFIK_CERTRESOLVER=""
	PA_TRAEFIK_CERTRESOLVER_ORIGEM="não encontrado"
	return 1
}

# ------------------------------------------------------------
# Rede
# ------------------------------------------------------------

# traefik_detectar_rede <container>
#
# Precedência: --providers.docker.network ganha de tudo, porque é
# a rede que o Traefik de fato usa para falar com os containers,
# mesmo estando ligado a várias.
traefik_detectar_rede() {
	local container="$1"

	local forcada
	forcada="$(traefik_argumentos "$container" |
		grep -oE -- '--providers\.docker\.network=[A-Za-z0-9_.-]+' |
		head -1 |
		sed -E 's/.*network=//')"

	if [[ -n "$forcada" ]]; then
		PA_TRAEFIK_NETWORK="$forcada"
		PA_TRAEFIK_NETWORK_ORIGEM="--providers.docker.network"
		return 0
	fi

	local modo
	modo="$(traefik_inspect "$container" '{{.HostConfig.NetworkMode}}')"

	if [[ "$modo" == "host" ]]; then
		PA_TRAEFIK_HOST_MODE=1
		PA_TRAEFIK_NETWORK=""
		PA_TRAEFIK_NETWORK_ORIGEM="container em network_mode: host"
		return 1
	fi

	local candidatas=()
	local rede
	# shellcheck disable=SC2016
	# $k é do template do Go, não do shell.
	while IFS= read -r rede; do
		[[ -z "$rede" ]] && continue

		local ignorar=0
		local reservada
		for reservada in "${PA_TRAEFIK_REDES_IGNORADAS[@]}"; do
			[[ "$rede" == "$reservada" ]] && ignorar=1
		done

		[[ "$ignorar" -eq 0 ]] && candidatas+=("$rede")
	done < <(traefik_inspect "$container" '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}
{{end}}')

	if [[ "${#candidatas[@]}" -eq 0 ]]; then
		return 1
	fi

	ui_escolher PA_TRAEFIK_NETWORK \
		"O Traefik está em mais de uma rede. Qual liga ao Mautic?" \
		"${candidatas[@]}"

	PA_TRAEFIK_NETWORK_ORIGEM="redes do container"
	return 0
}

# ------------------------------------------------------------
# Orquestração da detecção
# ------------------------------------------------------------

# traefik_detectar
#
# Preenche o que conseguir e devolve 1 quando não há Traefik.
# O que não for encontrado fica vazio, para o orquestrador
# perguntar com o padrão apenas como sugestão.
traefik_detectar() {
	if ! traefik_detectar_container; then
		return 1
	fi

	ui_ok "Traefik encontrado: ${PA_TRAEFIK_CONTAINER}"

	traefik_detectar_entrypoint "$PA_TRAEFIK_CONTAINER" || {
		PA_TRAEFIK_ENTRYPOINT=""
		PA_TRAEFIK_ENTRYPOINT_ORIGEM="não encontrado"
	}

	traefik_detectar_certresolver "$PA_TRAEFIK_CONTAINER" || true

	traefik_detectar_rede "$PA_TRAEFIK_CONTAINER" || true

	return 0
}

# traefik_mostrar_deteccao
#
# Tabela com valor e origem de cada item. A origem existe porque
# "detectado" sozinho não permite julgar: um valor vindo das
# flags de CLI merece mais confiança que um chute em cima do
# padrão.
traefik_mostrar_deteccao() {
	ui_secao "O que encontrei no Traefik desta máquina"

	printf '  %-16s %-24s %s\n' "ITEM" "VALOR" "ORIGEM"
	printf '  %-16s %-24s %s\n' \
		"rede" \
		"${PA_TRAEFIK_NETWORK:-<não encontrada>}" \
		"$PA_TRAEFIK_NETWORK_ORIGEM"
	printf '  %-16s %-24s %s\n' \
		"entrypoint" \
		"${PA_TRAEFIK_ENTRYPOINT:-<não encontrado>}" \
		"$PA_TRAEFIK_ENTRYPOINT_ORIGEM"
	printf '  %-16s %-24s %s\n' \
		"certresolver" \
		"${PA_TRAEFIK_CERTRESOLVER:-<nenhum>}" \
		"$PA_TRAEFIK_CERTRESOLVER_ORIGEM"

	ui_vazio

	if [[ "$PA_TRAEFIK_HOST_MODE" -eq 1 ]]; then
		ui_aviso "O Traefik está em network_mode: host."
		ui_detalhe "O label traefik.docker.network deixa de fazer sentido,"
		ui_detalhe "e o Mautic precisa ser alcançado por outro caminho."
		ui_detalhe "Informe a rede à mão com --traefik-network= se souber."
		ui_vazio
	fi

	if [[ -z "$PA_TRAEFIK_CERTRESOLVER" ]]; then
		ui_aviso "Nenhum certresolver encontrado."
		ui_detalhe "É o normal em quem termina o SSL fora da VPS, no"
		ui_detalhe "Cloudflare por exemplo. O label de certresolver será"
		ui_detalhe "omitido, e não preenchido com um palpite."
		ui_detalhe "Se estiver errado, use --traefik-certresolver=."
		ui_vazio
	fi
}
