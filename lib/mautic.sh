#!/usr/bin/env bash
# shellcheck shell=bash
#
# ============================================================
# lib/mautic.sh
# Geração do .env, subida da stack e conclusão da instalação.
#
# Depende de lib/ui.sh, lib/checks.sh e lib/traefik.sh.
#
# Quase tudo aqui saiu do teste B14, registrado no CLAUDE.md:
# a imagem NÃO conclui a instalação sozinha, o instalador por CLI
# reprova com fuso brasileiro, e a senha do admin não tem como ir
# por stdin. Cada um desses pontos vira um detalhe de
# implementação abaixo, e nenhum deles é óbvio lendo só a
# documentação do Mautic.
# ============================================================

# ------------------------------------------------------------
# Constantes
# ------------------------------------------------------------

PA_MAUTIC_DIR="/opt/playahead/mautic"
PA_MAUTIC_COMPOSE="${PA_MAUTIC_DIR}/docker-compose.yml"
PA_MAUTIC_ENV="${PA_MAUTIC_DIR}/.env"
PA_MAUTIC_CREDENCIAIS="${PA_MAUTIC_DIR}/credenciais.txt"

# Volume do banco. Serve de marca de instalação anterior: ele
# sobrevive a `docker compose down`, então é o que distingue
# "nunca instalado" de "instalado e derrubado".
PA_MAUTIC_VOLUME_BANCO="playahead_mautic_mariadb"

# Diretório de trabalho dentro do container.
#
# Não é o padrão da imagem, que é /var/www/html/docroot. O
# console vive em /var/www/html/bin/console, então sem o -w todo
# comando morre com "Could not open input file". Descoberto no
# teste B14.
PA_MAUTIC_WORKDIR="/var/www/html"

# Nome e sobrenome do admin. Decisão do CLAUDE.md: o Mautic exige
# os dois campos e nenhum deles vale uma pergunta.
PA_MAUTIC_ADMIN_NOME="Admin"
PA_MAUTIC_ADMIN_SOBRENOME="Play Ahead"

# Estado, preenchido durante a instalação e lido pelo bloco final.
PA_MAUTIC_SENHA_ADMIN=""
PA_MAUTIC_SENHA_BANCO=""
PA_MAUTIC_JA_INSTALADO=0

# ------------------------------------------------------------
# Segredos
# ------------------------------------------------------------

# mautic_gerar_senha
#
# `openssl rand`, nunca senha fixa. Os caracteres problemáticos
# são retirados de propósito: barra e mais sobrevivem mal a
# arquivo .env lido pelo compose, e cifrão vira expansão de
# variável em algum ponto da cadeia. Sobram 28 caracteres de
# alfabeto seguro, que é entropia de sobra.
mautic_gerar_senha() {
	openssl rand -base64 32 | tr -d '/+=\n' | head -c 28
}

# ------------------------------------------------------------
# Estado da instalação
# ------------------------------------------------------------

# mautic_volume_banco_existe
mautic_volume_banco_existe() {
	docker volume inspect "$PA_MAUTIC_VOLUME_BANCO" >/dev/null 2>&1
}

# mautic_detectar_estado
#
# Ecoa um de: nada, coerente, parcial.
#
# É a etapa 4 do fluxo, e roda antes de qualquer pergunta para
# não fazer a pessoa digitar o domínio à toa.
mautic_detectar_estado() {
	local tem_env=0 tem_volume=0

	[[ -f "$PA_MAUTIC_ENV" ]] && tem_env=1
	mautic_volume_banco_existe && tem_volume=1

	if [[ "$tem_env" -eq 0 && "$tem_volume" -eq 0 ]]; then
		printf 'nada\n'
	elif [[ "$tem_env" -eq 1 && "$tem_volume" -eq 1 ]]; then
		printf 'coerente\n'
	else
		printf 'parcial\n'
	fi
}

# mautic_abortar_parcial
#
# O estado perigoso: senha nova contra banco antigo gera erro de
# autenticação que parece bug do script. Parar e explicar é o
# comportamento decidido.
mautic_abortar_parcial() {
	local tem_env="nao" tem_volume="nao"
	[[ -f "$PA_MAUTIC_ENV" ]] && tem_env="sim"
	mautic_volume_banco_existe && tem_volume="sim"

	ui_fatal \
		"Encontrei uma instalação anterior pela metade." \
		"" \
		"    arquivo ${PA_MAUTIC_ENV}: ${tem_env}" \
		"    volume ${PA_MAUTIC_VOLUME_BANCO}: ${tem_volume}" \
		"" \
		"Seguir daqui geraria senha nova contra banco antigo, e o erro" \
		"de autenticação resultante pareceria bug do instalador." \
		"" \
		"Decida antes o que fazer com o que já está aí. O instalador não" \
		"apaga volume de banco de ninguém."
}

# ------------------------------------------------------------
# .env
# ------------------------------------------------------------

# mautic_gerar_env <dominio>
#
# Nunca sobrescreve .env existente: é a primeira regra da seção
# "nada destrutivo". Um .env reescrito com senha nova quebra o
# acesso ao banco que já está lá.
mautic_gerar_env() {
	local dominio="$1"

	mkdir -p "$PA_MAUTIC_DIR"

	if [[ -f "$PA_MAUTIC_ENV" ]]; then
		ui_ok "Arquivo .env já existe; mantido como está"
		PA_MAUTIC_SENHA_BANCO="$(
			awk -F= '/^MYSQL_PASSWORD=/ {print $2; exit}' "$PA_MAUTIC_ENV"
		)"
		return 0
	fi

	PA_MAUTIC_SENHA_BANCO="$(mautic_gerar_senha)"
	local senha_root
	senha_root="$(mautic_gerar_senha)"

	local mascara_antiga
	mascara_antiga="$(umask)"
	umask 077

	{
		printf '# Gerado pelo Play Ahead Installer em %s\n' "$(date -Is)"
		printf '# Não compartilhe este arquivo.\n\n'
		printf 'MAUTIC_DOMAIN=%s\n' "$dominio"
		printf 'MYSQL_PASSWORD=%s\n' "$PA_MAUTIC_SENHA_BANCO"
		printf 'MYSQL_ROOT_PASSWORD=%s\n' "$senha_root"

		# Só escreve os valores do Traefik quando eles diferem do
		# padrão do template, para o arquivo não ficar cheio de
		# linha redundante. O certresolver vazio é omitido de
		# propósito: o template tem default, e escrever vazio
		# produziria um label quebrado.
		if [[ -n "$PA_TRAEFIK_NETWORK" ]]; then
			printf 'TRAEFIK_NETWORK=%s\n' "$PA_TRAEFIK_NETWORK"
		fi
		if [[ -n "$PA_TRAEFIK_ENTRYPOINT" ]]; then
			printf 'TRAEFIK_ENTRYPOINT=%s\n' "$PA_TRAEFIK_ENTRYPOINT"
		fi
		if [[ -n "$PA_TRAEFIK_CERTRESOLVER" ]]; then
			printf 'TRAEFIK_CERTRESOLVER=%s\n' "$PA_TRAEFIK_CERTRESOLVER"
		fi
	} >"$PA_MAUTIC_ENV"

	umask "$mascara_antiga"
	chmod 600 "$PA_MAUTIC_ENV"

	ui_ok "Arquivo .env gerado em ${PA_MAUTIC_ENV}"
}

# mautic_gravar_compose <caminho_template>
#
# Duas origens possíveis para o compose, porque o script vive em
# dois formatos:
#
#   - rodando do repositório, copia templates/*.yml;
#   - rodando do dist/mautic7.sh, usa a função que o build.sh
#     embutiu, já que na VPS não existe pasta templates/.
#
# O template vai embutido como heredoc, e não em base64, para
# quem der `less mautic7.sh` conseguir ler o compose que vai ser
# instalado. Um blob opaco no meio do arquivo derrubaria a
# promessa de auditabilidade que justifica o passo do `less`.
mautic_gravar_compose() {
	local template="$1"

	mkdir -p "$PA_MAUTIC_DIR"

	if [[ -f "$PA_MAUTIC_COMPOSE" ]]; then
		ui_ok "docker-compose.yml já existe; mantido como está"
		return 0
	fi

	if declare -F mautic_template_embutido >/dev/null; then
		mautic_template_embutido >"$PA_MAUTIC_COMPOSE"
		ui_ok "docker-compose.yml gravado em ${PA_MAUTIC_DIR}"
		return 0
	fi

	if [[ ! -f "$template" ]]; then
		ui_fatal \
			"Não encontrei o template do compose em ${template}" \
			"Rodando a partir do repositório, execute na raiz dele." \
			"Rodando o instalador publicado, o template deveria estar" \
			"embutido — sinal de build quebrado. Baixe de novo."
	fi

	cp "$template" "$PA_MAUTIC_COMPOSE"
	ui_ok "docker-compose.yml gravado em ${PA_MAUTIC_DIR}"
}

# ------------------------------------------------------------
# Subida da stack, em três tempos
# ------------------------------------------------------------

# mautic_compose <argumentos...>
mautic_compose() {
	(cd "$PA_MAUTIC_DIR" && docker compose "$@")
}

# mautic_container_saudavel <servico>
mautic_container_saudavel() {
	local servico="$1"
	local id

	id="$(mautic_compose ps -q "$servico" 2>/dev/null)"
	[[ -n "$id" ]] || return 1

	local estado
	estado="$(docker inspect --format '{{.State.Health.Status}}' "$id" 2>/dev/null)"

	[[ "$estado" == "healthy" ]]
}

# mautic_subir_banco
mautic_subir_banco() {
	ui_passo "Subindo o banco de dados"

	mautic_compose up -d mariadb >/dev/null 2>&1 ||
		ui_fatal \
			"Falha ao subir o MariaDB." \
			"Veja o log:" \
			"" \
			"    cd ${PA_MAUTIC_DIR} && docker compose logs mariadb"

	ui_aguardar_ate "Aguardando o banco aceitar conexão" 180 \
		mautic_container_saudavel mariadb ||
		ui_fatal \
			"O banco subiu mas não ficou saudável." \
			"Veja o log:" \
			"" \
			"    cd ${PA_MAUTIC_DIR} && docker compose logs mariadb"
}

# mautic_subir_web
#
# Espera o healthcheck do mautic_web, que o template passou a ter
# depois do teste. Medido lá: healthy em 45s.
mautic_subir_web() {
	ui_passo "Subindo o Mautic"

	mautic_compose up -d mautic_web >/dev/null 2>&1 ||
		ui_fatal \
			"Falha ao subir o mautic_web." \
			"Veja o log:" \
			"" \
			"    cd ${PA_MAUTIC_DIR} && docker compose logs mautic_web"

	ui_aguardar_ate "Aguardando o Mautic responder" 300 \
		mautic_container_saudavel mautic_web ||
		ui_fatal \
			"O Mautic subiu mas não respondeu no tempo esperado." \
			"Veja o log:" \
			"" \
			"    cd ${PA_MAUTIC_DIR} && docker compose logs mautic_web"
}

# mautic_subir_resto
#
# Cron e worker só agora. Com depends_on: service_started eles
# subiriam antes de o banco estar instalado e ficariam em laço de
# erro, queimando CPU e poluindo o log justamente na hora em que
# a pessoa está olhando a tela.
mautic_subir_resto() {
	ui_passo "Subindo o agendador e os workers"

	mautic_compose up -d >/dev/null 2>&1 ||
		ui_fatal \
			"Falha ao subir cron e worker." \
			"O Mautic já está no ar; isto afeta campanhas e envios." \
			"Veja o log:" \
			"" \
			"    cd ${PA_MAUTIC_DIR} && docker compose logs mautic_cron"

	ui_ok "Agendador e workers no ar"
}

# ------------------------------------------------------------
# Conclusão da instalação
# ------------------------------------------------------------

# mautic_ja_instalado
#
# O teste B14 mostrou o sinal confiável: instalação concluída
# grava site_url no local.php. Antes disso o arquivo existe, mas
# só com parâmetros de banco.
mautic_ja_instalado() {
	mautic_compose exec -T -w "$PA_MAUTIC_WORKDIR" mautic_web \
		grep -q "site_url" config/local.php 2>/dev/null
}

# mautic_instalar <dominio> <email_admin>
#
# Duas coisas aqui não são escolha de estilo, e sim resultado de
# teste:
#
#   -d date.timezone=UTC   Sem isso o instalador reprova em
#                          "Your default timezone is not supported
#                          by PHP". A checagem do Symfony monta a
#                          lista de fusos aceitos a partir de
#                          DateTimeZone::listAbbreviations(), onde
#                          nenhum fuso brasileiro aparece desde o
#                          fim do horário de verão em 2019. O
#                          override vale só para este processo; a
#                          aplicação segue em America/Sao_Paulo.
#
#   --admin_password       O comando não lê stdin e não existe
#                          mautic:user:create. Testado: omitir a
#                          senha faz abortar com "[password] A
#                          value is required". Não há alternativa
#                          no Mautic 7.
mautic_instalar() {
	local dominio="$1"
	local email_admin="$2"

	if mautic_ja_instalado; then
		ui_ok "O Mautic já está instalado; não vou reinstalar por cima"
		# Lida pelo bloco final em main.sh.
		# shellcheck disable=SC2034
		PA_MAUTIC_JA_INSTALADO=1
		return 0
	fi

	ui_passo "Concluindo a instalação do Mautic"

	PA_MAUTIC_SENHA_ADMIN="$(mautic_gerar_senha)"

	if ! mautic_compose exec -T -w "$PA_MAUTIC_WORKDIR" mautic_web \
		php -d date.timezone=UTC bin/console mautic:install \
		--admin_firstname="$PA_MAUTIC_ADMIN_NOME" \
		--admin_lastname="$PA_MAUTIC_ADMIN_SOBRENOME" \
		--admin_email="$email_admin" \
		--admin_password="$PA_MAUTIC_SENHA_ADMIN" \
		--force \
		"https://${dominio}" >/dev/null 2>&1; then

		ui_fatal \
			"A instalação do Mautic falhou." \
			"Nada foi derrubado. Para ver o erro completo:" \
			"" \
			"    cd ${PA_MAUTIC_DIR}" \
			"    docker compose exec -w ${PA_MAUTIC_WORKDIR} mautic_web \\" \
			"      php -d date.timezone=UTC bin/console mautic:install \\" \
			"      --force https://${dominio}"
	fi

	ui_ok "Instalação concluída"
}

# ------------------------------------------------------------
# Credenciais
# ------------------------------------------------------------

# mautic_gravar_credenciais <dominio> <email_admin>
#
# Arquivo com chmod 600, que não é apagado automaticamente.
#
# O público esquece o terminal aberto e fecha; ficar sem acesso é
# pior que o arquivo local, que está no mesmo servidor onde o
# .env já vive. A senha do admin não está no .env e no banco está
# com hash: se o terminal se perder, ela se perde junto.
mautic_gravar_credenciais() {
	local dominio="$1"
	local email_admin="$2"

	local mascara_antiga
	mascara_antiga="$(umask)"
	umask 077

	{
		printf '============================================================\n'
		printf ' PLAY AHEAD - credenciais do Mautic\n'
		printf ' Gerado em %s\n' "$(date -Is)"
		printf '============================================================\n\n'
		printf 'URL:      https://%s\n\n' "$dominio"

		printf 'ADMIN\n'
		printf '  e-mail: %s\n' "$email_admin"
		if [[ -n "$PA_MAUTIC_SENHA_ADMIN" ]]; then
			printf '  senha:  %s\n' "$PA_MAUTIC_SENHA_ADMIN"
		else
			printf '  senha:  (definida em instalação anterior)\n'
		fi

		printf '\nBANCO DE DADOS\n'
		printf '  host:    mariadb\n'
		printf '  porta:   3306\n'
		printf '  base:    mautic\n'
		printf '  usuário: mautic\n'
		printf '  senha:   %s\n' "$PA_MAUTIC_SENHA_BANCO"

		printf '\nGuarde estes dados num gerenciador de senhas.\n'
		printf 'Este arquivo não é apagado automaticamente.\n'
	} >"$PA_MAUTIC_CREDENCIAIS"

	umask "$mascara_antiga"
	chmod 600 "$PA_MAUTIC_CREDENCIAIS"

	ui_ok "Credenciais gravadas em ${PA_MAUTIC_CREDENCIAIS}"
}

# ------------------------------------------------------------
# Verificação anti-404
# ------------------------------------------------------------

# mautic_verificar_roteamento <dominio>
#
# Sem este passo o modo de falha mais caro do projeto continua
# silencioso: o container sobe, o Mautic funciona, e o domínio
# devolve 404 porque os nomes do Traefik estão errados.
#
# Não derruba nada em caso de falha. Imprime o estado e como
# corrigir, conforme a regra de não haver rollback.
mautic_verificar_roteamento() {
	local dominio="$1"

	ui_passo "Conferindo se o domínio chega no Mautic"

	local codigo=""
	local _tentativa
	for _tentativa in $(seq 1 20); do
		codigo="$(curl -sk -o /dev/null -w '%{http_code}' \
			--max-time 15 "https://${dominio}/" 2>/dev/null || true)"

		case "$codigo" in
			200 | 302 | 301)
				ui_ok "O domínio responde ${codigo}: roteamento correto"
				return 0
				;;
		esac

		sleep 6
	done

	if [[ "$codigo" == "404" ]]; then
		ui_erro "O Traefik respondeu, mas não roteou para o Mautic."
		ui_vazio
		ui_info "O proxy está no ar e atendeu o domínio, mas não encontrou"
		ui_info "o roteador do Mautic. Quase sempre é nome errado."
		ui_vazio
		ui_info "Valores usados:"
		ui_detalhe "rede         ${PA_TRAEFIK_NETWORK:-<padrão do template>}"
		ui_detalhe "entrypoint   ${PA_TRAEFIK_ENTRYPOINT:-<padrão do template>}"
		ui_detalhe "certresolver ${PA_TRAEFIK_CERTRESOLVER:-<omitido>}"
		ui_vazio
		ui_info "Para corrigir, edite o .env e suba de novo:"
		ui_detalhe "nano ${PA_MAUTIC_ENV}"
		ui_detalhe "cd ${PA_MAUTIC_DIR} && docker compose up -d"
		ui_vazio
		ui_info "Confira os nomes reais com:"
		ui_detalhe "docker inspect <container-do-traefik>"
		ui_vazio
		return 1
	fi

	ui_aviso "O domínio respondeu ${codigo:-nada} em vez de 200."
	ui_detalhe "O Mautic está no ar dentro da máquina."
	ui_detalhe "Pode ser propagação de DNS ou emissão de certificado,"
	ui_detalhe "que às vezes levam alguns minutos. Tente abrir no"
	ui_detalhe "navegador daqui a pouco: https://${dominio}"
	ui_vazio

	return 1
}
