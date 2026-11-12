#!/bin/bash
# Na VPS de TESTE: deixa o cache do Mautic pela metade, de propósito, e
# mostra se reiniciar a web conserta.
#
#   bash cache-pela-metade.sh <domínio do Mautic>
#
# É a reprodução do defeito de 2026-11-11: o painel respondia 500 depois
# de uma instalação que tinha terminado com saída 0. O cache do Symfony
# é montado em duas partes: primeiro o container, depois o resto, como
# os proxies do Doctrine. Se o processo que monta morre entre as duas,
# o cache fica com o container e sem o resto, e ninguém termina o
# trabalho: a tela de login responde 500 até o cache ser jogado fora.
#
# Na instalação, quem matava era o `docker compose restart` da limpeza
# de cache, 10 segundos depois de pedido. Acertar esse instante é
# sorte: oito limpezas seguidas, com o site recebendo pedidos, passaram.
# Aqui um vigia dentro do container mata os processos do Apache no
# instante em que o arquivo do container aparece.
#
# Com o compose de hoje, em que a web joga o cache fora toda vez que
# sobe, o resultado esperado é 500 antes do reinício e 200 depois. Com
# um compose anterior a 2026-11-12, o 500 continua depois do reinício.

DOMINIO="${1:?domínio do Mautic}"
URL="https://${DOMINIO}/s/login"
C=mautic-mautic_web-1
cd /opt/playahead/mautic || exit 1

proxies() {
	docker exec "$C" sh -c \
		'ls /var/www/html/var/cache/prod/doctrine/orm/Proxies 2>/dev/null | wc -l'
}

saudavel() {
	[ "$(docker inspect --format '{{.State.Health.Status}}' "$C" 2>/dev/null)" = healthy ]
}

login() {
	curl -sk -o /dev/null -w '%{http_code}' --max-time 90 \
		--resolve "${DOMINIO}:443:127.0.0.1" "$URL"
}

echo "antes: proxies=$(proxies) login=$(login)"

# Tira o cache com o site no ar, como a limpeza antiga fazia.
docker compose exec -T -u www-data -w /var/www/html/var/cache mautic_web \
	sh -c 'mv prod prod.velho 2>/dev/null; rm -rf prod.velho pro_ pro~'

# O vigia: mata os filhos do Apache (os processos do www-data, usuário
# 33) assim que o arquivo do container aparece.
docker exec "$C" rm -f /tmp/vigia
# A expansão acontece dentro do container, não aqui.
# shellcheck disable=SC2016
docker exec -d "$C" sh -c '
	while [ ! -f /var/www/html/var/cache/prod/AppKernelProdContainer.php ]; do :; done
	for p in /proc/[0-9]*; do
		grep -q "^Uid:[[:space:]]*33" "$p/status" 2>/dev/null && kill -9 "${p#/proc/}"
	done
	echo disparou >/tmp/vigia'

echo "o pedido que montava o cache respondeu: $(login)"
sleep 3
echo "vigia: $(docker exec "$C" cat /tmp/vigia 2>/dev/null || echo 'não disparou')"
echo "cache pela metade: proxies=$(proxies) login=$(login)"

inicio=$(date +%s)
docker compose restart mautic_web >/dev/null 2>&1
for _ in $(seq 1 150); do
	saudavel && break
	sleep 2
done
echo "reinício: $(($(date +%s) - inicio)) s até healthy"
sleep 5
echo "depois do reinício: proxies=$(proxies) login=$(login)"
