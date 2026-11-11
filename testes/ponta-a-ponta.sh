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
#   - o menu, que exige terminal;
#   - o envio de e-mail de verdade;
#   - a troca de versão de verdade no modo de atualização. Aqui a
#     atualização roda sobre a mesma versão, com o compose alterado
#     de propósito: prova o backup, a regravação e a subida, mas não
#     a migração do banco entre duas versões.
# ============================================================

set -euo pipefail

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
passo "Segunda execução não reinstala"
# ------------------------------------------------------------

if bash dist/mautic7.sh --yes >"${LOGS}/mautic-de-novo.log" 2>&1 &&
	grep -q "Instalação encontrada" "${LOGS}/mautic-de-novo.log"; then
	ok "mautic7.sh de novo: saiu com 0 dizendo que a instalação existe"
else
	falhou "mautic7.sh de novo não reconheceu a instalação"
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
passo "Resultado"
# ------------------------------------------------------------

guardar_logs

if [[ "$FALHAS" -gt 0 ]]; then
	echo "  ${FALHAS} conferência(s) falharam. Logs em ${LOGS}."
	exit 1
fi

echo "  Todas as conferências passaram. Logs em ${LOGS}."
