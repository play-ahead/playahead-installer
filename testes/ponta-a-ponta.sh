#!/usr/bin/env bash
# shellcheck shell=bash
#
# ============================================================
# testes/ponta-a-ponta.sh
#
# Teste fixo do instalador: roda o dist/base.sh e o dist/mautic7.sh
# numa máquina Ubuntu 24.04 limpa e confere o resultado. É o que o
# workflow do GitHub roda em todo pedido de atualização, e é ele
# que aprova uma versão nova (ver "Política de versões" no
# CLAUDE.md). Também roda numa VPS de teste, do mesmo jeito.
#
# Uso, na raiz do repositório:
#
#     sudo bash testes/ponta-a-ponta.sh
#
# Sem DNS público não há Let's Encrypt. Os dois domínios de teste
# ficam no /etc/hosts apontando para 127.0.0.1, os instaladores
# rodam com --skip-dns-check, e o roteamento é conferido pelo
# Traefik com o certificado padrão dele (curl -k). A conferência
# de certificado dos próprios instaladores vai avisar que ele não é
# válido, e isso é esperado aqui.
#
# O que este teste NÃO cobre, e continua dependendo de VPS de
# verdade com DNS público:
#
#   - a checagem de DNS (A e AAAA), que roda com --skip-dns-check;
#   - a emissão do certificado do Let's Encrypt;
#   - o firewall do provedor e o bloqueio de portas de SMTP;
#   - a instalação do Docker e o swap, quando a máquina já vem com
#     Docker e muita memória, como a do GitHub (cenário 1.5, 16 GB);
#   - rodar um instalador pelo menu. A lista do menu é conferida
#     aqui, num terminal de mentira, mas a escolha é sempre "sair";
#   - o envio de e-mail de verdade;
#   - a troca de versão de verdade no modo de atualização. Aqui a
#     atualização roda sobre a mesma versão, com o compose alterado
#     de propósito: prova o backup, a regravação e a subida, mas não
#     a migração do banco entre duas versões.
# ============================================================

set -euo pipefail

# Os logs deste teste trazem a tela final dos instaladores, com as
# senhas geradas. São descartáveis, mas não precisam nascer legíveis
# por todo usuário da máquina.
umask 077

DOMINIO_MAUTIC="mautic.ci.test"
DOMINIO_PORTAINER="portainer.ci.test"
EMAIL="ci@playahead.com.br"
LOGS="${LOGS:-/tmp/teste-instalador}"

FALHAS=0

passo() { printf '\n== %s\n' "$*"; }
ok() { printf '  ok     %s\n' "$*"; }
falhou() {
	printf '  FALHA  %s\n' "$*"
	FALHAS=$((FALHAS + 1))
}

# confere <descrição> <comando...>
confere() {
	local descricao="$1"
	shift
	if "$@" >/dev/null 2>&1; then
		ok "$descricao"
	else
		falhou "$descricao"
	fi
}

# recomendada <variável> <arquivo do dist>
#
# A versão que o próprio dist declara. O teste compara com o que
# subiu, em vez de repetir números que envelhecem.
recomendada() {
	awk -F'"' -v v="$1=" 'index($0, v) == 1 { print $2; exit }' "$2"
}

guardar_logs() {
	mkdir -p "$LOGS"
	local c
	for c in $(docker ps -a --format '{{.Names}}' 2>/dev/null); do
		docker logs "$c" >"${LOGS}/container-${c}.log" 2>&1 || true
	done
	cp /opt/playahead/*/docker-compose.yml "$LOGS"/ 2>/dev/null || true
}

if [[ "$EUID" -ne 0 ]]; then
	echo "Rode com sudo: sudo bash testes/ponta-a-ponta.sh"
	exit 1
fi

if [[ ! -f dist/base.sh || ! -f dist/mautic7.sh ]]; then
	echo "Rode na raiz do repositório: não achei dist/base.sh e dist/mautic7.sh."
	exit 1
fi

mkdir -p "$LOGS"

# ------------------------------------------------------------
passo "Domínios de teste no /etc/hosts"
# ------------------------------------------------------------

if ! grep -q " ${DOMINIO_MAUTIC}" /etc/hosts; then
	printf '127.0.0.1 %s %s\n' "$DOMINIO_MAUTIC" "$DOMINIO_PORTAINER" >>/etc/hosts
fi
ok "${DOMINIO_MAUTIC} e ${DOMINIO_PORTAINER} apontam para 127.0.0.1"

# ------------------------------------------------------------
passo "Menu, antes de instalar"
# ------------------------------------------------------------
#
# O menu só conversa com terminal. O testes/vps/pty-rodar.py dá um a
# ele, espera a pergunta e responde 0, que é sair sem instalar nada.

# tela_do_menu <arquivo de log>
#
# Devolve 1 quando não deu para rodar o menu (sem python3, ou o menu
# não chegou à pergunta).
tela_do_menu() {
	local log="$1"

	if ! command -v python3 >/dev/null 2>&1; then
		return 1
	fi

	# O timeout de fora cobre o caso de o menu nunca chegar à
	# pergunta: sem ele, o teste ficaria esperando para sempre.
	timeout 240 python3 testes/vps/pty-rodar.py --sem-cor --tempo 120 --log "$log" \
		--resposta "Número da opção=0" \
		-- bash dist/playahead.sh >/dev/null 2>&1 || return 1

	grep -q "Número da opção" "$log"
}

# item_do_menu <arquivo de log> <nome>
#
# A linha da lista com aquele nome. O número pode vir como "1" ou
# "1)", conforme o tema.
item_do_menu() {
	grep -E "^ *[0-9]+\)? +${2} " "$1" | head -n 1 || true
}

MENU_TESTAVEL=1
if tela_do_menu "${LOGS}/menu-antes.log"; then
	confere "o cabeçalho do menu é o geral (Play Ahead Installer)" \
		grep -q "Play Ahead Installer" "${LOGS}/menu-antes.log"

	for nome in "Base" "Mautic 7"; do
		linha="$(item_do_menu "${LOGS}/menu-antes.log" "$nome")"
		if [[ -z "$linha" ]]; then
			falhou "menu: ${nome} não aparece na lista"
		elif [[ "$linha" == *instalado* ]]; then
			falhou "menu: ${nome} aparece como instalado numa máquina limpa"
		else
			ok "menu: ${nome} na lista, sem a marca de instalado"
		fi
	done
else
	MENU_TESTAVEL=0
	printf '  aviso  não consegui rodar o menu num terminal de teste (python3?); a lista não foi conferida\n'
fi

# ------------------------------------------------------------
passo "Base"
# ------------------------------------------------------------

if bash dist/base.sh --yes --acme-email="$EMAIL" \
	--portainer-domain="$DOMINIO_PORTAINER" --skip-dns-check \
	>"${LOGS}/base.log" 2>&1; then
	ok "base.sh saiu com 0"
else
	falhou "base.sh saiu com $?"
	tail -n 40 "${LOGS}/base.log"
	guardar_logs
	exit 1
fi

# ------------------------------------------------------------
passo "Mautic"
# ------------------------------------------------------------

if bash dist/mautic7.sh --yes --domain="$DOMINIO_MAUTIC" \
	--admin-email="$EMAIL" --skip-dns-check \
	>"${LOGS}/mautic.log" 2>&1; then
	ok "mautic7.sh saiu com 0"
else
	falhou "mautic7.sh saiu com $?"
	tail -n 40 "${LOGS}/mautic.log"
	guardar_logs
	exit 1
fi

# ------------------------------------------------------------
passo "Containers no ar"
# ------------------------------------------------------------

CONTAINERS=(
	traefik-traefik-1
	portainer-portainer-1
	mautic-mariadb-1
	mautic-mautic_web-1
	mautic-mautic_cron-1
	mautic-mautic_worker-1
)

for c in "${CONTAINERS[@]}"; do
	estado="$(docker inspect -f '{{.State.Status}}{{if .State.Health}} {{.State.Health.Status}}{{end}}' "$c" 2>/dev/null || echo ausente)"
	case "$estado" in
		"running" | "running healthy") ok "${c}: ${estado}" ;;
		*) falhou "${c}: ${estado}" ;;
	esac
done

# ------------------------------------------------------------
passo "Versões: as recomendadas do dist/"
# ------------------------------------------------------------

imagem_de() { docker inspect -f '{{.Config.Image}}' "$1" 2>/dev/null || true; }

declare -A ESPERADO=(
	[traefik-traefik-1]="traefik:$(recomendada PA_TRAEFIK_VERSAO dist/base.sh)"
	[portainer-portainer-1]="portainer/portainer-ce:$(recomendada PA_PORTAINER_VERSAO dist/base.sh)"
	[mautic-mariadb-1]="$(recomendada PA_MARIADB_IMAGEM dist/mautic7.sh)"
	[mautic-mautic_web-1]="$(recomendada PA_MAUTIC_IMAGEM_RECOMENDADA dist/mautic7.sh)"
	[mautic-mautic_cron-1]="$(recomendada PA_MAUTIC_IMAGEM_RECOMENDADA dist/mautic7.sh)"
	[mautic-mautic_worker-1]="$(recomendada PA_MAUTIC_IMAGEM_RECOMENDADA dist/mautic7.sh)"
)

for c in "${CONTAINERS[@]}"; do
	atual="$(imagem_de "$c")"
	if [[ "$atual" == "${ESPERADO[$c]}" ]]; then
		ok "${c}: ${atual}"
	else
		falhou "${c}: ${atual:-?}, esperado ${ESPERADO[$c]}"
	fi
done

versao_mautic="$(recomendada PA_MAUTIC_IMAGEM_RECOMENDADA dist/mautic7.sh)"
versao_mautic="${versao_mautic##*:}"
versao_mautic="${versao_mautic%-apache}"
confere "o console diz Mautic ${versao_mautic}" \
	sh -c "docker exec -u www-data -w /var/www/html mautic-mautic_web-1 php bin/console --version | grep -q 'Mautic ${versao_mautic} '"

# ------------------------------------------------------------
passo "Instalação do Mautic"
# ------------------------------------------------------------

confere "marca de instalação concluída" test -f /opt/playahead/mautic/.instalacao-concluida
confere "site_url gravado no local.php" \
	docker exec mautic-mautic_web-1 grep -q site_url /var/www/html/config/local.php
confere "migrações registradas (doctrine:migrations:up-to-date)" \
	docker exec -u www-data -w /var/www/html mautic-mautic_web-1 \
	php -d date.timezone=UTC bin/console doctrine:migrations:up-to-date
confere "credenciais.txt com chmod 600" \
	sh -c "[ \"\$(stat -c %a /opt/playahead/mautic/credenciais.txt)\" = 600 ]"
confere "credenciais.txt diz a versão instalada" \
	grep -q "Mautic ${versao_mautic} " /opt/playahead/mautic/credenciais.txt

# conferir_cache_mautic <quando>
#
# O cache do Mautic tem de estar inteiro. Um cache montado pela metade
# tem o container do Symfony e quase nenhum proxy do Doctrine (3 de
# 102, medido em 2026-11-11), e a tela de login responde 500. Usada
# depois da instalação, do reinício e da atualização.
conferir_cache_mautic() {
	local quando="$1" proxies
	proxies="$(docker exec mautic-mautic_web-1 sh -c \
		'ls /var/www/html/var/cache/prod/doctrine/orm/Proxies 2>/dev/null | wc -l' 2>/dev/null || true)"
	if [[ "${proxies:-0}" -ge 50 ]]; then
		ok "${quando}: cache inteiro (${proxies} proxies do Doctrine)"
	else
		falhou "${quando}: cache pela metade (${proxies:-0} proxies do Doctrine)"
	fi
}

conferir_cache_mautic "depois de instalar"

# ------------------------------------------------------------
passo "Workers"
# ------------------------------------------------------------

workers="$(docker exec mautic-mautic_worker-1 ps -eo args 2>/dev/null |
	grep -c 'messenger:consume .*--time-limit=300' || true)"
if [[ "$workers" -eq 6 ]]; then
	ok "6 workers com --time-limit=300"
else
	falhou "${workers} workers com --time-limit=300, esperados 6"
fi

# ------------------------------------------------------------
passo "Log com rotação"
# ------------------------------------------------------------

for c in "${CONTAINERS[@]}"; do
	driver="$(docker inspect -f '{{.HostConfig.LogConfig.Type}}' "$c" 2>/dev/null || true)"
	if [[ "$driver" == "local" ]]; then
		ok "${c}: driver local"
	else
		falhou "${c}: driver ${driver:-?}, esperado local"
	fi
done

# ------------------------------------------------------------
passo "Roteamento pelo Traefik"
# ------------------------------------------------------------

corpo="$(mktemp)"
medida="$(curl -skL --max-redirs 10 --max-time 30 \
	--resolve "${DOMINIO_MAUTIC}:443:127.0.0.1" \
	-o "$corpo" -w '%{http_code} %{url_effective}' \
	"https://${DOMINIO_MAUTIC}/" 2>/dev/null || true)"
if [[ "$medida" == "200 https://${DOMINIO_MAUTIC}/s/login" ]] && grep -q '_username' "$corpo"; then
	ok "Mautic: a raiz chega na tela de login (${medida})"
else
	falhou "Mautic: ${medida:-sem resposta}"
fi
rm -f "$corpo"

codigo="$(curl -skL --max-time 30 --resolve "${DOMINIO_PORTAINER}:443:127.0.0.1" \
	-o /dev/null -w '%{http_code}' "https://${DOMINIO_PORTAINER}/" 2>/dev/null || true)"
if [[ "$codigo" == "200" ]]; then
	ok "Portainer: 200"
else
	falhou "Portainer: ${codigo:-sem resposta}"
fi

codigo="$(curl -s --max-time 30 --resolve "${DOMINIO_MAUTIC}:80:127.0.0.1" \
	-o /dev/null -w '%{http_code}' "http://${DOMINIO_MAUTIC}/" 2>/dev/null || true)"
case "$codigo" in
	301 | 302 | 307 | 308) ok "HTTP redireciona para HTTPS (${codigo})" ;;
	*) falhou "HTTP não redirecionou: ${codigo:-sem resposta}" ;;
esac

# ------------------------------------------------------------
passo "Segurança do que ficou publicado"
# ------------------------------------------------------------

# cabecalhos_mautic
#
# Os cabeçalhos da tela de login, pelo Traefik. Usada depois da
# instalação e de novo depois da atualização, que recria o container.
cabecalhos_mautic() {
	curl -skI --max-time 30 --resolve "${DOMINIO_MAUTIC}:443:127.0.0.1" \
		"https://${DOMINIO_MAUTIC}/s/login" 2>/dev/null || true
}

# conferir_seguranca_mautic <quando>
conferir_seguranca_mautic() {
	local quando="$1" cabecalhos codigo
	cabecalhos="$(cabecalhos_mautic)"

	if grep -qiE '^set-cookie:.*; *secure' <<<"$cabecalhos"; then
		ok "${quando}: cookie de sessão com secure"
	else
		falhou "${quando}: cookie de sessão sem secure"
	fi

	if grep -qi '^strict-transport-security: *max-age=31536000' <<<"$cabecalhos"; then
		ok "${quando}: HSTS no Mautic"
	else
		falhou "${quando}: sem HSTS no Mautic"
	fi

	# O cabeçalho Forwarded de um visitante não pode derrubar o pixel.
	codigo="$(curl -sk --max-time 30 --resolve "${DOMINIO_MAUTIC}:443:127.0.0.1" \
		-H 'Forwarded: for=203.0.113.7;proto=http' -o /dev/null -w '%{http_code}' \
		"https://${DOMINIO_MAUTIC}/mtracking.gif" 2>/dev/null || true)"
	if [[ "$codigo" == "200" ]]; then
		ok "${quando}: pixel responde 200 com o cabeçalho Forwarded"
	else
		falhou "${quando}: pixel com o cabeçalho Forwarded respondeu ${codigo:-nada}"
	fi
}

conferir_seguranca_mautic "depois de instalar"

if curl -skI --max-time 30 --resolve "${DOMINIO_PORTAINER}:443:127.0.0.1" \
	"https://${DOMINIO_PORTAINER}/" 2>/dev/null |
	grep -qi '^strict-transport-security: *max-age=31536000'; then
	ok "HSTS no Portainer"
else
	falhou "sem HSTS no Portainer"
fi

publicado="$(docker inspect -f '{{index .Config.Labels "traefik.enable"}}' mautic-mautic_web-1 2>/dev/null || true)"
if [[ "$publicado" == "true" ]]; then
	ok "o Mautic terminou publicado no Traefik (traefik.enable=true)"
else
	falhou "o Mautic terminou com traefik.enable=${publicado:-?}"
fi

# O root do banco só existe para conexão de dentro do container.
hosts_root="$(docker exec mautic-mariadb-1 sh -c \
	'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mariadb -N -uroot -e "select group_concat(host order by host) from mysql.user where user=\"root\""' \
	2>/dev/null || true)"
if [[ "$hosts_root" == "localhost" ]]; then
	ok "root do banco só em localhost"
else
	falhou "root do banco em: ${hosts_root:-não consegui ler}"
fi

# Só o Traefik publica porta no host.
publicadas="$(docker ps --format '{{.Names}} {{.Ports}}' | grep -E '0\.0\.0\.0:|:::' | awk '{print $1}' | sort -u | tr '\n' ' ')"
if [[ "$publicadas" == "traefik-traefik-1 " ]]; then
	ok "só o Traefik publica porta no host"
else
	falhou "containers com porta publicada: ${publicadas:-nenhum}"
fi

# ------------------------------------------------------------
passo "Reiniciar a web refaz o cache"
# ------------------------------------------------------------
#
# Limpar o cache do Mautic é reiniciar a web: o container joga o cache
# fora ao subir e monta outro antes de atender. Aqui o cache é
# estragado de propósito (sem os proxies do Doctrine, como fica um
# cache montado pela metade) e tem de voltar inteiro depois do
# reinício. Um arquivo de root em var/ confere que o dono é devolvido.

docker exec mautic-mautic_web-1 sh -c '
	rm -rf /var/www/html/var/cache/prod/doctrine/orm/Proxies
	touch /var/www/html/var/cache/prod/de-root /var/www/html/var/de-root' >/dev/null 2>&1 || true

if (cd /opt/playahead/mautic && docker compose restart mautic_web) >"${LOGS}/reinicio-web.log" 2>&1; then
	ok "docker compose restart mautic_web saiu com 0"
else
	falhou "docker compose restart mautic_web saiu com $?"
fi

voltou=0
for _ in $(seq 1 120); do
	if [[ "$(docker inspect -f '{{.State.Health.Status}}' mautic-mautic_web-1 2>/dev/null || true)" == "healthy" ]]; then
		voltou=1
		break
	fi
	sleep 2
done
if [[ "$voltou" -eq 1 ]]; then
	ok "a web voltou a ficar healthy"
else
	falhou "a web não ficou healthy em 4 minutos depois do reinício"
fi

conferir_cache_mautic "depois de reiniciar"

if docker exec mautic-mautic_web-1 test -e /var/www/html/var/cache/prod/de-root; then
	falhou "o cache antigo sobreviveu ao reinício"
else
	ok "o cache antigo foi jogado fora no reinício"
fi

dono="$(docker exec mautic-mautic_web-1 stat -c '%U' /var/www/html/var/de-root 2>/dev/null || true)"
if [[ "$dono" == "www-data" ]]; then
	ok "arquivo de root em var/ voltou para o www-data"
else
	falhou "arquivo de root em var/ ficou com ${dono:-dono desconhecido}"
fi
docker exec mautic-mautic_web-1 rm -f /var/www/html/var/de-root >/dev/null 2>&1 || true

medida="$(
	curl -skL --max-redirs 10 --max-time 60 --resolve "${DOMINIO_MAUTIC}:443:127.0.0.1" \
		-o /dev/null -w '%{http_code} %{url_effective}' "https://${DOMINIO_MAUTIC}/" 2>/dev/null || true
)"
if [[ "$medida" == "200 https://${DOMINIO_MAUTIC}/s/login" ]]; then
	ok "Mautic no ar depois do reinício (${medida})"
else
	falhou "Mautic depois do reinício: ${medida:-sem resposta}"
fi

conferir_seguranca_mautic "depois de reiniciar"

# Depois de subir, nada em var/ pode ter ficado com outro dono: o que
# o container roda antes do Apache tem de rodar como www-data.
de_outro_dono="$(docker exec mautic-mautic_web-1 sh -c 'find /var/www/html/var ! -user www-data | wc -l' 2>/dev/null || true)"
if [[ "${de_outro_dono:-1}" -eq 0 ]]; then
	ok "tudo em var/ é do www-data depois do reinício"
else
	falhou "${de_outro_dono:-?} arquivo(s) em var/ com outro dono depois do reinício"
fi

# O cache é apagado como root, toda vez que o container sobe. Se o
# usuário do site trocar var/cache por um link simbólico, o root não
# pode apagar nada no lugar para onde o link aponta. Aqui o alvo é
# uma pasta de root com uma "prod" dentro, que tem de sobreviver.
docker exec mautic-mautic_web-1 sh -c '
	mkdir -p /srv/alvo/prod && echo a >/srv/alvo/prod/arquivo && chown -R root:root /srv/alvo' >/dev/null 2>&1 || true
docker exec -u www-data mautic-mautic_web-1 sh -c '
	mv /var/www/html/var/cache /var/www/html/var/cache.guardado &&
	ln -s /srv/alvo /var/www/html/var/cache' >/dev/null 2>&1 || true

if [[ "$(docker exec mautic-mautic_web-1 readlink /var/www/html/var/cache 2>/dev/null || true)" == "/srv/alvo" ]]; then
	(cd /opt/playahead/mautic && docker compose restart mautic_web) >>"${LOGS}/reinicio-web.log" 2>&1 || true
	sleep 5

	if docker exec mautic-mautic_web-1 test -e /srv/alvo/prod/arquivo; then
		ok "com var/cache trocada por um link, o reinício não apagou nada no alvo"
	else
		falhou "com var/cache trocada por um link, o reinício apagou a pasta prod do alvo"
	fi

	dono="$(docker exec mautic-mautic_web-1 stat -c '%U' /srv/alvo/prod/arquivo 2>/dev/null || true)"
	if [[ "$dono" == "root" || -z "$dono" ]]; then
		ok "o chown do reinício não seguiu o link"
	else
		falhou "o chown do reinício seguiu o link: o arquivo do alvo ficou com ${dono}"
	fi
else
	falhou "não consegui montar o teste do link simbólico em var/cache"
fi

# Desfaz, e a web tem de voltar inteira.
docker exec mautic-mautic_web-1 sh -c '
	rm -f /var/www/html/var/cache
	rm -rf /srv/alvo
	[ -d /var/www/html/var/cache.guardado ] && mv /var/www/html/var/cache.guardado /var/www/html/var/cache' >/dev/null 2>&1 || true
(cd /opt/playahead/mautic && docker compose restart mautic_web) >>"${LOGS}/reinicio-web.log" 2>&1 || true

voltou=0
for _ in $(seq 1 120); do
	if [[ "$(docker inspect -f '{{.State.Health.Status}}' mautic-mautic_web-1 2>/dev/null || true)" == "healthy" ]]; then
		voltou=1
		break
	fi
	sleep 2
done
if [[ "$voltou" -eq 1 ]]; then
	ok "a web voltou a ficar healthy depois do teste do link"
else
	falhou "a web não ficou healthy depois do teste do link"
fi
conferir_cache_mautic "depois do teste do link"

# ------------------------------------------------------------
passo "Segunda execução não reinstala"
# ------------------------------------------------------------

if bash dist/mautic7.sh --yes >"${LOGS}/mautic-de-novo.log" 2>&1 &&
	grep -q "Instalação encontrada" "${LOGS}/mautic-de-novo.log"; then
	ok "mautic7.sh de novo: saiu com 0 dizendo que a instalação existe"
else
	falhou "mautic7.sh de novo não reconheceu a instalação"
fi

# A base de novo, sem dizer nada sobre o Portainer. Com um Portainer
# no ar ela não pergunta o subdomínio nem exige a opção: diz que ele
# foi encontrado, e não recria nada.
antes="$(docker ps --format '{{.Names}} {{.ID}}' | sort)"

if bash dist/base.sh --yes >"${LOGS}/base-de-novo.log" 2>&1; then
	ok "base.sh de novo, sem opção do Portainer: saiu com 0"
else
	falhou "base.sh de novo, sem opção do Portainer, saiu com $?"
	tail -n 20 "${LOGS}/base-de-novo.log"
fi

confere "base.sh de novo: disse que o Portainer foi encontrado e será mantido" \
	grep -q "Já existe um Portainer nesta máquina" "${LOGS}/base-de-novo.log"

if [[ "$(docker ps --format '{{.Names}} {{.ID}}' | sort)" == "$antes" ]]; then
	ok "base.sh de novo: nenhum container foi recriado"
else
	falhou "base.sh de novo: a lista de containers mudou"
fi

# ------------------------------------------------------------
passo "Modo de atualização: nada a fazer numa instalação nova"
# ------------------------------------------------------------

if bash dist/mautic7.sh --atualizar --yes >"${LOGS}/mautic-atualizar-nada.log" 2>&1 &&
	grep -q "Nada a atualizar" "${LOGS}/mautic-atualizar-nada.log"; then
	ok "mautic7.sh --atualizar: nada a atualizar, saiu com 0"
else
	falhou "mautic7.sh --atualizar não reconheceu a instalação em dia"
fi

if bash dist/base.sh --atualizar --yes >"${LOGS}/base-atualizar-nada.log" 2>&1 &&
	grep -q "Nada a atualizar" "${LOGS}/base-atualizar-nada.log"; then
	ok "base.sh --atualizar: nada a atualizar, saiu com 0"
else
	falhou "base.sh --atualizar não reconheceu a base em dia"
fi

confere "nenhum backup criado sem atualização" \
	sh -c "[ ! -d /opt/playahead/mautic/backups ] && [ ! -d /opt/playahead/backups ]"

# ------------------------------------------------------------
passo "Modo de atualização: compose alterado é regravado, com backup"
# ------------------------------------------------------------
#
# Trocar de versão de verdade exigiria instalar uma versão antiga
# antes, e isso é teste de VPS. O que dá para provar aqui é o caminho
# inteiro da atualização sobre o mesmo banco: para, faz o dump,
# guarda o compose antigo, regrava o novo, sobe e confere. A linha
# acrescentada ao compose é o que faz a atualização ter o que fazer.

printf '# linha acrescentada pelo teste\n' >>/opt/playahead/mautic/docker-compose.yml

if bash dist/mautic7.sh --atualizar --yes >"${LOGS}/mautic-atualizar.log" 2>&1; then
	ok "mautic7.sh --atualizar saiu com 0"
else
	falhou "mautic7.sh --atualizar saiu com $?"
	tail -n 40 "${LOGS}/mautic-atualizar.log"
fi

confere "a tela avisou que o compose tinha sido alterado" \
	grep -q "foi alterado depois da instalação" "${LOGS}/mautic-atualizar.log"

backup="$(find /opt/playahead/mautic/backups -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n 1)"
if [[ -n "$backup" ]]; then
	ok "backup em ${backup}"
	confere "dump do banco completo (Dump completed)" \
		sh -c "gunzip -c '${backup}/banco.sql.gz' | tail -n 1 | grep -q 'Dump completed'"
	confere "compose antigo guardado, com a linha do teste" \
		grep -q "linha acrescentada pelo teste" "${backup}/docker-compose.yml"
	confere ".env e instruções de volta no backup" \
		sh -c "[ -f '${backup}/.env' ] && [ -f '${backup}/COMO-RESTAURAR.txt' ]"
	# A pasta e os arquivos com segredo não podem dar acesso a grupo
	# nem a outros. Confere os bits, e não o número exato do modo: uma
	# pasta pode herdar o setgid da pasta de cima sem que isso abra
	# nada. Falhando, mostra o modo de cada um.
	abertos="$(find "$backup" -maxdepth 1 -perm /077 -printf '%m %p\n' 2>/dev/null)"
	if [[ -z "$abertos" ]]; then
		ok "backup sem acesso para grupo nem para outros"
	else
		falhou "backup com acesso além do root: ${abertos//$'\n'/, }"
	fi
else
	falhou "a atualização não deixou backup"
fi

confere "compose regravado, sem a linha do teste" \
	sh -c "! grep -q 'linha acrescentada pelo teste' /opt/playahead/mautic/docker-compose.yml"
confere "registro do compose confere com o arquivo" \
	sh -c "cd /opt/playahead/mautic && sha256sum --status -c .compose.sha256"
confere "nenhuma atualização ficou em andamento" \
	test ! -e /opt/playahead/mautic/.atualizacao-em-andamento
confere ".env intocado pela atualização" \
	sh -c "cmp -s /opt/playahead/mautic/.env '${backup}/.env'"

for c in mautic-mariadb-1 mautic-mautic_web-1 mautic-mautic_cron-1 mautic-mautic_worker-1; do
	estado="$(docker inspect -f '{{.State.Status}}{{if .State.Health}} {{.State.Health.Status}}{{end}}' "$c" 2>/dev/null || echo ausente)"
	case "$estado" in
		"running" | "running healthy") ok "depois da atualização, ${c}: ${estado}" ;;
		*) falhou "depois da atualização, ${c}: ${estado}" ;;
	esac
done

medida="$(curl -skL --max-redirs 10 --max-time 30 \
	--resolve "${DOMINIO_MAUTIC}:443:127.0.0.1" \
	-o /dev/null -w '%{http_code} %{url_effective}' \
	"https://${DOMINIO_MAUTIC}/" 2>/dev/null || true)"
if [[ "$medida" == "200 https://${DOMINIO_MAUTIC}/s/login" ]]; then
	ok "Mautic no ar depois da atualização (${medida})"
else
	falhou "Mautic depois da atualização: ${medida:-sem resposta}"
fi

# A atualização recria o container. Se ele atendesse com o cache que
# veio na imagem, o cookie de sessão sairia sem secure.
conferir_seguranca_mautic "depois de atualizar"
conferir_cache_mautic "depois de atualizar"

printf '# linha acrescentada pelo teste\n' >>/opt/playahead/traefik/docker-compose.yml

if bash dist/base.sh --atualizar --yes >"${LOGS}/base-atualizar.log" 2>&1; then
	ok "base.sh --atualizar saiu com 0"
else
	falhou "base.sh --atualizar saiu com $?"
	tail -n 40 "${LOGS}/base-atualizar.log"
fi

abertos="$(find /opt/playahead/backups -perm /077 -printf '%m %p\n' 2>/dev/null)"
if [[ -z "$abertos" ]]; then
	ok "backup da base sem acesso para grupo nem para outros"
else
	falhou "backup da base com acesso além do root: ${abertos//$'\n'/, }"
fi

confere "backup da base com o compose antigo do Traefik" \
	sh -c "grep -q 'linha acrescentada pelo teste' /opt/playahead/backups/base-*/traefik/docker-compose.yml"
confere "compose do Traefik regravado" \
	sh -c "! grep -q 'linha acrescentada pelo teste' /opt/playahead/traefik/docker-compose.yml"

codigo="$(curl -skL --max-time 30 --resolve "${DOMINIO_PORTAINER}:443:127.0.0.1" \
	-o /dev/null -w '%{http_code}' "https://${DOMINIO_PORTAINER}/" 2>/dev/null || true)"
if [[ "$codigo" == "200" ]]; then
	ok "Portainer no ar depois da atualização da base"
else
	falhou "Portainer depois da atualização da base: ${codigo:-sem resposta}"
fi

# ------------------------------------------------------------
passo "Menu, depois de instalar"
# ------------------------------------------------------------

if [[ "$MENU_TESTAVEL" -eq 1 ]] && tela_do_menu "${LOGS}/menu-depois.log"; then
	for nome in "Base" "Mautic 7"; do
		linha="$(item_do_menu "${LOGS}/menu-depois.log" "$nome")"
		if [[ "$linha" == *instalado* ]]; then
			ok "menu: ${nome} aparece como instalado"
		else
			falhou "menu: ${nome} sem a marca de instalado: ${linha:-linha não encontrada}"
		fi
	done
else
	printf '  aviso  menu não conferido depois de instalar\n'
fi

# ------------------------------------------------------------
passo "Contador de etapas"
# ------------------------------------------------------------
#
# Cada instalador anuncia o total de etapas e conta de 1 até ele. Uma
# etapa que não aparece faz o contador pular número, e uma a mais
# passa do total.
#
# O formato do título de etapa é do tema ("[3/8] Título", "3 de 8
# Título"), então o teste lê do próprio dist/ o que vem antes e depois
# do título, em vez de repetir um formato que muda com o visual.

FORMATO_ANTES="$(recomendada PA_TEMA_ETAPA_ANTES dist/mautic7.sh)"
FORMATO_DEPOIS="$(recomendada PA_TEMA_ETAPA_DEPOIS dist/mautic7.sh)"

# literal <texto>
#
# O texto com os caracteres especiais de expressão regular escapados.
literal() {
	# O cifrão dentro das aspas simples é do sed, e não uma variável.
	# shellcheck disable=SC2016
	printf '%s' "$1" | sed 's,[][\.*^$(){}?+|],\\&,g'
}

# titulo_de_etapa <n> <total>
#
# A expressão regular da linha de título da etapa n de total.
titulo_de_etapa() {
	local antes="${FORMATO_ANTES//\{n\}/$1}" depois="${FORMATO_DEPOIS//\{n\}/$1}"
	antes="${antes//\{t\}/$2}"
	depois="${depois//\{t\}/$2}"

	printf '^ *%s.*%s$' "$(literal "$antes")" "$(literal "$depois")"
}

# conferir_etapas <arquivo de log> <total esperado>
conferir_etapas() {
	local log="$1" total="$2" n linha anterior=0 problema=""

	for n in $(seq 1 "$total"); do
		linha="$(grep -nE -m1 -- "$(titulo_de_etapa "$n" "$total")" "$log" 2>/dev/null | cut -d: -f1 || true)"

		if [[ -z "$linha" ]]; then
			problema+=" falta a ${n};"
		elif [[ "$linha" -le "$anterior" ]]; then
			problema+=" a ${n} veio antes da $((n - 1));"
		else
			anterior="$linha"
		fi
	done

	if grep -qE -- "$(titulo_de_etapa "$((total + 1))" "$total")" "$log" 2>/dev/null; then
		problema+=" passou do total;"
	fi

	if [[ -z "$problema" ]]; then
		ok "$(basename "$log"): etapas de 1 a ${total}, em ordem e sem pular"
	else
		falhou "$(basename "$log"): contador de etapas:${problema}"
	fi
}

if [[ "${FORMATO_ANTES}${FORMATO_DEPOIS}" == *"{n}"* ]]; then
	conferir_etapas "${LOGS}/base.log" 7
	conferir_etapas "${LOGS}/base-de-novo.log" 7
	conferir_etapas "${LOGS}/mautic.log" 8
	conferir_etapas "${LOGS}/mautic-atualizar.log" 6
	conferir_etapas "${LOGS}/base-atualizar.log" 5
else
	falhou "não achei o formato do título de etapa no dist/mautic7.sh"
fi

# ------------------------------------------------------------
passo "Resultado"
# ------------------------------------------------------------

guardar_logs

if [[ "$FALHAS" -gt 0 ]]; then
	echo "  ${FALHAS} conferência(s) falharam. Logs em ${LOGS}."
	exit 1
fi

echo "  Todas as conferências passaram. Logs em ${LOGS}."
