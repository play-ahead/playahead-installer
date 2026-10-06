#!/usr/bin/env bash
# shellcheck shell=bash
#
# ============================================================
# lib/portainer.sh
# Instalação do Portainer, a última etapa da base.
#
# Depende de lib/ui.sh, lib/checks.sh, lib/docker.sh e das
# variáveis de rede preenchidas por lib/traefik.sh.
#
# REGRA QUE VALE PARA O ARQUIVO TODO: nenhuma função aqui chama
# ui_fatal. O Portainer roda por último dentro da base, e a
# decisão de projeto é que uma falha aqui seja aviso, não
# desastre: a pessoa termina com Docker, Traefik e a rede do
# proxy funcionando de qualquer jeito. Toda função devolve
# status; quem decide o que fazer é o base_main.sh.
#
# A SENHA DO ADMIN NASCE AQUI, e não na primeira visita.
#
# Desde a 2.43, um Portainer novo exige um setup token, impresso
# só no log do container, para criar o administrador, e fecha a
# criação depois de 5 minutos. Para o público do vídeo isso é uma
# parede: abrir o domínio e ver um campo pedindo um token que não
# está em lugar nenhum da tela. Medido em 2026-10-06: na VPS de
# teste o log tinha o setup_token e, minutos depois, "the
# Portainer instance timed out for security purposes".
#
# A documentação oficial (docs.portainer.io/faqs/installing/
# setup-token) oferece --admin-password-file para pré-definir a
# senha, sem token, e o indica para instalação gerenciada. A
# referência de CLI (docs.portainer.io/advanced/cli) diz o
# formato: o arquivo contém a senha em TEXTO PURO. Quem espera
# hash bcrypt é a outra flag, --admin-password. O usuário criado
# é "admin".
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
PA_PORTAINER_CREDENCIAIS="${PA_PORTAINER_DIR}/credenciais.txt"

# Arquivo que o Portainer lê na primeira subida. Texto puro, sem
# quebra de linha no fim (a documentação usa `echo -n`), chmod
# 600. Fica no disco depois da instalação porque o compose aponta
# para ele: sem o arquivo, recriar o container falharia.
PA_PORTAINER_SENHA_ARQ="${PA_PORTAINER_DIR}/admin_password"

# Onde o arquivo aparece dentro do container. Montado como
# somente leitura: o Portainer só precisa ler.
PA_PORTAINER_SENHA_CONTAINER="/run/playahead/admin_password"

PA_PORTAINER_USUARIO="admin"

# Preenchidas na instalação, lidas pelo bloco final.
PA_PORTAINER_INSTALADO=0
PA_PORTAINER_SENHA=""

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
# Senha
# ------------------------------------------------------------

# portainer_gerar_senha
#
# `openssl rand`, nunca senha fixa, com o mesmo alfabeto da senha
# do Mautic: sem barra, mais e igual, que sobrevivem mal em
# arquivo e em linha de comando. 28 caracteres passam folgado do
# mínimo de 12 que o Portainer exige.
portainer_gerar_senha() {
	openssl rand -base64 32 | tr -d '/+=\n' | head -c 28
}

# portainer_preparar_senha
#
# Gera e grava a senha, ou reaproveita a que já existe.
#
# Reaproveitar não é detalhe. O Portainer só lê o arquivo quando
# cria o administrador pela primeira vez; depois disso o arquivo
# é ignorado. Gerar uma senha nova numa reexecução deixaria o
# credenciais.txt mostrando uma senha que o Portainer nunca
# conheceu.
portainer_preparar_senha() {
	if [[ -s "$PA_PORTAINER_SENHA_ARQ" ]]; then
		PA_PORTAINER_SENHA="$(cat "$PA_PORTAINER_SENHA_ARQ")"
		ui_ok "Senha do admin do Portainer já existe; mantida"
		return 0
	fi

	PA_PORTAINER_SENHA="$(portainer_gerar_senha)"

	if [[ -z "$PA_PORTAINER_SENHA" ]]; then
		ui_aviso "Não consegui gerar a senha do Portainer."
		return 1
	fi

	local mascara_antiga
	mascara_antiga="$(umask)"
	umask 077

	# printf '%s', e não echo: sem quebra de linha no fim. Uma
	# quebra de linha entraria na senha, e a pessoa nunca a
	# digitaria.
	printf '%s' "$PA_PORTAINER_SENHA" >"$PA_PORTAINER_SENHA_ARQ"

	umask "$mascara_antiga"
	chmod 600 "$PA_PORTAINER_SENHA_ARQ"

	ui_ok "Senha do admin do Portainer gerada"
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
# na prática, root nesta máquina. É por isso que a senha é
# gerada pelo script, longa e aleatória, e guardada com chmod
# 600.
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
#
# A senha do usuário admin vem do arquivo admin_password, nesta
# pasta, pelo --admin-password-file. O Portainer só o lê na
# primeira subida, para criar o administrador; trocar o arquivo
# depois NÃO troca a senha. Para trocar, use o próprio painel.
# ============================================================

services:

  portainer:
    image: portainer/portainer-ce:${PA_PORTAINER_VERSAO}
    restart: unless-stopped

    command:
      - -H
      - unix:///var/run/docker.sock
      - --admin-password-file
      - ${PA_PORTAINER_SENHA_CONTAINER}

    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - playahead_portainer_data:/data
      - ${PA_PORTAINER_SENHA_ARQ}:${PA_PORTAINER_SENHA_CONTAINER}:ro

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
# aviso na tela, e deixa o base_main.sh seguir para o bloco final.
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
	# de abortar: o Portainer é a última peça da base, e derrubar
	# a execução por causa do DNS dele seria trocar o certo pelo
	# duvidoso.
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

	portainer_preparar_senha || return 1

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
		ui_detalhe "Docker e Traefik não foram afetados e seguem no ar."
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

	portainer_gravar_credenciais
	portainer_verificar_roteamento "$PA_PORTAINER_DOMINIO" || true

	return 0
}

# portainer_respondendo
#
# Pergunta ao próprio container, sem depender do Traefik nem do
# DNS. A imagem do Portainer não traz curl nem wget, então o
# teste é feito de fora: se o container está em execução e não
# reiniciando, o serviço subiu.
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
# Mesma regra da verificação do Mautic: segue os redirecionamentos
# e só aceita 200. Sempre como aviso.
#
# A versão anterior aceitava 307 como sucesso, e o 307 era
# justamente o sintoma do problema: o Portainer redirecionando
# para /timeout.html depois de fechar a criação do admin.
# Medido no teste do cenário 1, em 2026-09-12.
portainer_verificar_roteamento() {
	local dominio="$1"

	ui_passo "Conferindo se o domínio abre o Portainer"

	local medida="" codigo="" url_final=""
	local _tentativa

	for _tentativa in $(seq 1 12); do
		medida="$(
			curl -skL --max-redirs 10 --max-time 15 -o /dev/null \
				-w '%{http_code}|%{url_effective}' \
				"https://${dominio}/" 2>/dev/null
		)" || true

		codigo="${medida%%|*}"
		url_final="${medida#*|}"

		if [[ "$codigo" == "200" ]] && [[ "$url_final" != *timeout* ]]; then
			ui_ok "O domínio abre o Portainer"
			return 0
		fi

		sleep 5
	done

	if [[ "$url_final" == *timeout* ]]; then
		ui_aviso "O Portainer fechou a criação do administrador."
		ui_detalhe "Não devia acontecer com a senha pré-definida."
		ui_detalhe "Veja o log: cd ${PA_PORTAINER_DIR} && docker compose logs"
	elif [[ "$codigo" == "404" ]]; then
		ui_aviso "O Traefik respondeu, mas não roteou para o Portainer."
		ui_detalhe "Confira os nomes em ${PA_PORTAINER_DIR}/docker-compose.yml"
	else
		ui_aviso "O domínio do Portainer respondeu ${codigo:-nada}."
		ui_detalhe "Pode ser propagação de DNS ou emissão de certificado."
		ui_detalhe "Tente abrir daqui a pouco: https://${dominio}"
	fi

	return 1
}

# ------------------------------------------------------------
# Credenciais e bloco final
# ------------------------------------------------------------

# portainer_gravar_credenciais
#
# Arquivo próprio, em /opt/playahead/portainer, com chmod 600,
# como o do Mautic. Arquivo próprio e não anexado ao do Mautic
# porque a base roda antes e sozinha: quando o Portainer sobe,
# não existe Mautic nenhum, e cada pasta em /opt/playahead guarda
# o que é dela.
#
# Não é apagado automaticamente, pela mesma razão do Mautic: o
# público fecha o terminal, e ficar sem acesso ao painel que
# controla a máquina inteira é pior que o arquivo local.
portainer_gravar_credenciais() {
	local mascara_antiga
	mascara_antiga="$(umask)"
	umask 077

	{
		printf '============================================================\n'
		printf ' PLAY AHEAD - credenciais do Portainer\n'
		printf ' Gerado em %s\n' "$(date -Is)"
		printf '============================================================\n\n'
		printf 'URL:      https://%s\n' "$PA_PORTAINER_DOMINIO"
		printf 'usuário:  %s\n' "$PA_PORTAINER_USUARIO"
		printf 'senha:    %s\n' "$PA_PORTAINER_SENHA"
		printf '\nGuarde estes dados num gerenciador de senhas.\n'
		printf 'Este arquivo não é apagado automaticamente.\n'
		printf '\nQuem entra no Portainer controla todos os containers\n'
		printf 'desta máquina. Se trocar a senha, troque pelo painel:\n'
		printf 'editar o arquivo admin_password depois da primeira\n'
		printf 'subida não tem efeito nenhum.\n'
	} >"$PA_PORTAINER_CREDENCIAIS"

	umask "$mascara_antiga"
	chmod 600 "$PA_PORTAINER_CREDENCIAIS"

	ui_ok "Credenciais gravadas em ${PA_PORTAINER_CREDENCIAIS}"
}

# portainer_bloco_final
#
# Entra no bloco final da base. Sem prazo, sem token e sem
# comando de restart: com a senha pré-definida não existe janela
# de criação do administrador para expirar.
portainer_bloco_final() {
	[[ "$PA_PORTAINER_INSTALADO" -eq 1 ]] || return 0

	ui_vazio
	ui_info "Portainer"
	ui_detalhe "URL:      https://${PA_PORTAINER_DOMINIO}"
	ui_detalhe "usuário:  ${PA_PORTAINER_USUARIO}"
	ui_detalhe "senha:    ${PA_PORTAINER_SENHA}"
	ui_detalhe "salvo em: ${PA_PORTAINER_CREDENCIAIS}"
	ui_vazio
	ui_info "Quem entra no Portainer controla todos os containers"
	ui_info "desta máquina. Guarde a senha num gerenciador de senhas."
}
