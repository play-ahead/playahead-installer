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

# Versões recomendadas: as que passaram no teste. Nunca tag
# flutuante (`7-apache`, `10.11`, `latest`); ver "Política de
# versões" no CLAUDE.md. A tag `7-apache` trocou de 7.1.2 para 7.2.2
# em 2026-10-26 sem ninguém pedir, e a instalação daquele dia saiu
# com uma versão que nunca tinha sido testada aqui.
#
# 7.2.2 corrige 8 avisos de segurança que atingem toda a 7.x antes
# dela, entre eles uma execução remota de código; a linha 7.1 parou
# na 7.1.3 e não recebeu a correção.
#
# Os mesmos valores estão como padrão no template do compose, e o
# build.sh confere que os dois batem: o template também é usado à
# mão, sem o script.
#
PA_MAUTIC_IMAGEM_RECOMENDADA="mautic/mautic:7.2.2-apache"
PA_MARIADB_IMAGEM="mariadb:10.11.19"

# Lista de tags do Mautic no Docker Hub, para a opção "mais nova".
# O endereço é o documentado (/v2/namespaces/.../tags). O name= e o
# ordering= funcionaram em 2026-10-27, mas não estão na documentação:
# se pararem, a consulta volta sem a 7.x e a pergunta some, sem
# quebrar nada.
PA_MAUTIC_HUB_TAGS="https://hub.docker.com/v2/namespaces/mautic/repositories/mautic/tags?page_size=100&name=7.&ordering=last_updated"

# Escolha da versão: recomendada ou mais-nova, como na flag
# --versao=. A imagem final vai para o compose instalado.
PA_MAUTIC_VERSAO_ESCOLHA="recomendada"
PA_MAUTIC_VERSAO_FLAG=""
PA_MAUTIC_IMAGEM="$PA_MAUTIC_IMAGEM_RECOMENDADA"

PA_MAUTIC_DIR="/opt/playahead/mautic"
PA_MAUTIC_COMPOSE="${PA_MAUTIC_DIR}/docker-compose.yml"
PA_MAUTIC_ENV="${PA_MAUTIC_DIR}/.env"
PA_MAUTIC_CREDENCIAIS="${PA_MAUTIC_DIR}/credenciais.txt"

# Marca de instalação concluída, gravada no último passo. É ela, e
# não o .env nem o volume, que diz que a instalação foi até o fim:
# o volume nasce no `up -d mariadb`, antes do mautic:install, e o
# site_url nasce no mautic:install, antes de idioma, fuso, workers,
# teste de SMTP e credenciais. Ver mautic_detectar_estado.
PA_MAUTIC_MARCA="${PA_MAUTIC_DIR}/.instalacao-concluida"

# Preenchida pelo modo de atualização; vai para o credenciais.txt.
PA_MAUTIC_NOTA_ATUALIZACAO=""

# Volume do banco. Ele sobrevive a `docker compose down`, então é o
# que distingue "nunca instalado" de "instalado e derrubado".
PA_MAUTIC_VOLUME_BANCO="playahead_mautic_mariadb"

# Volume da configuração, onde mora o config/local.php.
PA_MAUTIC_VOLUME_CONFIG="playahead_mautic_config"

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

# Pacotes de idioma. As duas URLs saíram do
# app/bundles/CoreBundle/Config/config.php do próprio Mautic 7,
# nas chaves translations_list_url e translations_fetch_url. Não
# foram adivinhadas.
PA_MAUTIC_LANG_MANIFEST="https://language-packs.mautic.com/manifest.json"
PA_MAUTIC_LANG_BASE="https://language-packs.mautic.com/"

# Faixa de proxy confiável, gravada em config/parameters_local.php.
#
# 0.0.0.0/0 confia em qualquer origem, e aqui isso é seguro: a
# porta 80 do mautic_web não é publicada no host, então ninguém
# fora da rede do Docker consegue abrir conexão com ela. Quem
# alcança o Apache é o Traefik e mais nada.
#
# A alternativa, gravar as faixas privadas ou o IP do container
# do Traefik, é mais restrita no papel e mais frágil na prática:
# a faixa varia por máquina, no cenário 2 pode ser qualquer uma,
# e o IP muda quando o proxy é recriado. Errar isso traz o laço
# de redirecionamento de volta, e sem nenhuma mensagem de erro.
PA_MAUTIC_PROXY_CONFIAVEL="0.0.0.0/0"

# Estado, preenchido durante a instalação e lido pelo bloco final.
PA_MAUTIC_SENHA_ADMIN=""
PA_MAUTIC_SENHA_BANCO=""
PA_MAUTIC_JA_INSTALADO=0

# 1 quando o script está retomando uma instalação interrompida.
PA_MAUTIC_RETOMANDO=0

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
# Ecoa um de: nada, concluida, retomar, perigoso.
#
# É a etapa 3 do fluxo, e roda antes de qualquer pergunta para
# não fazer a pessoa digitar o domínio à toa.
#
#   .env  volume  marca   estado
#   não   não     -       nada       instalação nova
#   sim   sim     sim     concluida  reconcilia e sai com 0
#   sim   -       não     retomar    segue de onde parou
#   não   sim     -       perigoso   banco sem a senha dele
#   sim   não     sim     perigoso   instalação concluída sem banco
#
# Até 2026-10-22, .env mais volume já contava como instalação
# completa. Só que o volume nasce no `up -d mariadb`, antes do
# mautic:install: reproduzido com um docker falso, uma queda entre
# os dois fazia a segunda execução dizer "instalação completa", sair
# com 0 e apontar para um credenciais.txt que não existia. E .env
# sem volume (download do MariaDB falhando) abortava para sempre,
# falando de um banco antigo que não existia. Esse caso é seguro de
# retomar: o banco nasce com a senha que já está no .env.
#
# O último caso existe porque retomar ali criaria um banco vazio
# para um config/local.php que já tem site_url: o mautic:install
# seria pulado, e o Mautic subiria sem nenhuma tabela.
mautic_detectar_estado() {
	local tem_env=0 tem_volume=0 tem_marca=0

	[[ -f "$PA_MAUTIC_ENV" ]] && tem_env=1
	mautic_volume_banco_existe && tem_volume=1
	[[ -f "$PA_MAUTIC_MARCA" ]] && tem_marca=1

	if [[ "$tem_env" -eq 0 && "$tem_volume" -eq 0 ]]; then
		printf 'nada\n'
	elif [[ "$tem_env" -eq 0 ]]; then
		printf 'perigoso\n'
	elif [[ "$tem_marca" -eq 1 && "$tem_volume" -eq 1 ]]; then
		printf 'concluida\n'
	elif [[ "$tem_marca" -eq 1 ]]; then
		printf 'perigoso\n'
	else
		printf 'retomar\n'
	fi
}

# mautic_abortar_perigoso
#
# Os dois estados em que seguir daria errado. Parar e explicar é o
# comportamento decidido, e o instalador não apaga volume de banco
# de ninguém.
mautic_abortar_perigoso() {
	if [[ ! -f "$PA_MAUTIC_ENV" ]]; then
		ui_fatal \
			"Existe o banco de uma instalação anterior, mas não o .env dele." \
			"" \
			"    volume ${PA_MAUTIC_VOLUME_BANCO}: existe" \
			"    arquivo ${PA_MAUTIC_ENV}: não existe" \
			"" \
			"A senha desse banco estava no .env. Sem ela o instalador não" \
			"consegue usá-lo, e uma senha nova contra ele daria erro de" \
			"autenticação, que pareceria bug do instalador." \
			"" \
			"Se você tem uma cópia do .env, devolva-a para esta pasta e" \
			"rode de novo. O instalador não apaga volume de banco."
	fi

	ui_fatal \
		"A instalação foi concluída antes, mas o banco não existe mais." \
		"" \
		"    marca ${PA_MAUTIC_MARCA}: existe" \
		"    volume ${PA_MAUTIC_VOLUME_BANCO}: não existe" \
		"" \
		"Seguir criaria um banco vazio para uma configuração que já se" \
		"diz instalada, e o Mautic subiria sem nenhuma tabela." \
		"" \
		"Se o volume foi apagado de propósito e você quer instalar do" \
		"zero, mova a pasta ${PA_MAUTIC_DIR} para outro lugar e rode de novo."
}

# mautic_env_valor <chave>
#
# Ecoa o valor de uma chave do .env, ou nada.
mautic_env_valor() {
	[[ -f "$PA_MAUTIC_ENV" ]] || return 0
	awk -F= -v chave="$1" '$1 == chave { sub(/^[^=]*=/, ""); print; exit }' \
		"$PA_MAUTIC_ENV"
}

# mautic_compose_label <nome_do_label>
#
# Ecoa o valor de um label do mautic_web como o compose instalado o
# resolve, já com o .env aplicado. Nada quando o label não existe,
# que é o caso do certresolver omitido.
mautic_compose_label() {
	[[ -f "$PA_MAUTIC_COMPOSE" ]] || return 0
	mautic_compose config 2>/dev/null |
		awk -v nome="$1:" '$1 == nome { $1 = ""; sub(/^ /, ""); gsub(/"/, ""); print; exit }' ||
		true
}

# mautic_site_url_gravado
#
# Verdadeiro quando o config/local.php já tem site_url, ou seja,
# quando o mautic:install terminou. Lê direto do volume, pelo host,
# para funcionar antes de qualquer container estar de pé.
mautic_site_url_gravado() {
	local origem
	origem="$(docker volume inspect -f '{{.Mountpoint}}' "$PA_MAUTIC_VOLUME_CONFIG" 2>/dev/null)" ||
		return 1
	grep -q "site_url" "${origem}/local.php" 2>/dev/null
}

# mautic_ler_credenciais
#
# Na retomada, lê o e-mail e a senha do admin do credenciais.txt,
# que passou a ser gravado logo depois do mautic:install. Sem isto,
# a regravação do fim trocaria a senha verdadeira pelo texto
# "(definida em instalação anterior)".
mautic_ler_credenciais() {
	[[ -f "$PA_MAUTIC_CREDENCIAIS" ]] || return 0

	local email senha
	email="$(awk '/^ADMIN/ {a = 1} a && /^  e-mail:/ {print $2; exit}' "$PA_MAUTIC_CREDENCIAIS")" || true
	senha="$(awk '/^ADMIN/ {a = 1} a && /^  senha:/ {print $2; exit}' "$PA_MAUTIC_CREDENCIAIS")" || true

	[[ -z "$PA_EMAIL_ADMIN" && -n "$email" ]] && PA_EMAIL_ADMIN="$email"
	[[ -n "$senha" && "$senha" != \(* ]] && PA_MAUTIC_SENHA_ADMIN="$senha"
	return 0
}

# mautic_email_admin_do_banco
#
# Último recurso para o e-mail do admin na retomada, quando o
# mautic:install terminou e o credenciais.txt não chegou a ser
# gravado. O banco precisa estar de pé.
#
# A senha vai por MYSQL_PWD, e não por -p: argumento de linha de
# comando aparece na lista de processos do host, inclusive o de
# processo que roda dentro de container.
mautic_email_admin_do_banco() {
	# A variável é expandida dentro do container, não aqui.
	# shellcheck disable=SC2016
	mautic_compose exec -T mariadb sh -c \
		'MYSQL_PWD="$MYSQL_PASSWORD" mariadb -N -umautic mautic -e "select email from users order by id limit 1"' \
		2>/dev/null | head -n 1 || true
}

# mautic_gravar_marca
#
# Último passo da instalação. Só depois disto uma nova execução
# trata a instalação como concluída.
mautic_gravar_marca() {
	printf 'Instalação concluída em %s pelo %s %s.\n' \
		"$(date -Is)" "$PA_FERRAMENTA" "$PA_VERSAO" >"$PA_MAUTIC_MARCA"
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

	mautic_escrever_template "$PA_MAUTIC_COMPOSE" "$template"

	[[ -z "$PA_TRAEFIK_CERTRESOLVER" ]] && mautic_compose_sem_certresolver
	mautic_compose_definir_imagem
	mautic_compose_registrar_hash

	ui_ok "docker-compose.yml gravado em ${PA_MAUTIC_DIR}"
}

# mautic_escrever_template <destino> <caminho_template>
#
# Grava o template do compose em <destino>, sem nenhum ajuste. Usada
# pela instalação e pelo modo de atualização, que gera o compose
# novo num arquivo ao lado antes de trocar.
mautic_escrever_template() {
	local destino="$1"
	local template="$2"

	if declare -F mautic_template_embutido >/dev/null; then
		mautic_template_embutido >"$destino"
		return 0
	fi

	if [[ ! -f "$template" ]]; then
		ui_fatal \
			"Não encontrei o template do compose em ${template}" \
			"Rodando a partir do repositório, execute na raiz dele." \
			"Rodando o instalador publicado, o template deveria estar" \
			"embutido. Sinal de build quebrado; baixe de novo."
	fi

	cp "$template" "$destino"
}

# mautic_compose_registrar_hash
#
# O sha256 do compose como o instalador o gravou, para o modo de
# atualização saber se a pessoa mexeu nele. Ver
# docker_compose_registrar_hash.
mautic_compose_registrar_hash() {
	docker_compose_registrar_hash "$PA_MAUTIC_DIR"
}

# mautic_compose_situacao
#
# Ecoa um de: intacto, alterado, sem-registro.
mautic_compose_situacao() {
	docker_compose_situacao "$PA_MAUTIC_DIR"
}

# mautic_compose_sem_certresolver
#
# Tira o label de certresolver do compose instalado, para quem
# termina o TLS fora da VPS ou tem um Traefik sem resolver.
#
# Omitir a chave no .env não basta: o template tem default, e o
# ${TRAEFIK_CERTRESOLVER:-letsencrypt} vira "letsencrypt" do mesmo
# jeito. Medido com docker compose config em 2026-10-22. O label
# apontaria para um resolver que não existe nesse Traefik.
#
# A troca é no arquivo instalado, e não no template, para o build
# continuar conferindo o template embutido byte a byte. Se a linha
# não estiver lá no formato esperado, para em vez de seguir com o
# label errado.
#
# O arquivo é o compose instalado, a não ser que venha outro: o modo
# de atualização aplica o mesmo ajuste no compose novo, antes de
# colocá-lo no lugar.
mautic_compose_sem_certresolver() {
	local arquivo="${1:-$PA_MAUTIC_COMPOSE}"
	local label='traefik.http.routers.playahead-mautic.tls.certresolver='

	if ! grep -q -- "$label" "$arquivo"; then
		ui_fatal \
			"Não achei o label de certresolver no compose para retirar." \
			"Sinal de que o template mudou e esta função não acompanhou."
	fi

	sed -i "s|^\( *\)- \"${label}.*\"\$|\1# Sem certresolver: o TLS é terminado fora desta VPS.|" \
		"$arquivo"

	if grep -q -- "$label" "$arquivo"; then
		ui_fatal \
			"Não consegui retirar o label de certresolver do compose." \
			"Confira ${arquivo} antes de rodar de novo."
	fi
}

# ------------------------------------------------------------
# Subida da stack, em três tempos
# ------------------------------------------------------------

# mautic_compose <argumentos...>
mautic_compose() {
	(cd "$PA_MAUTIC_DIR" && docker compose "$@")
}

# mautic_console <argumentos do bin/console...>
#
# Todo comando de console passa por aqui, e a razão é permissão.
#
# `docker compose exec` entra como **root** por padrão. O Apache
# roda como www-data, e `var/cache` não está em volume: vive na
# camada de escrita do container, de dono www-data. Qualquer
# console rodado como root deixa arquivo de root lá dentro, e a
# partir daí o Apache não consegue mais escrever, e o Mautic
# responde 500.
#
# Medido na VPS de teste: um `cache:clear` como root deixou 30.737
# arquivos de root em var/cache, e o site caiu. Não é hipótese.
#
# Os dois outros detalhes vêm do teste B14: `-w` porque o console
# está um nível acima do diretório de trabalho da imagem, e
# `-d date.timezone=UTC` porque fuso brasileiro reprova na
# checagem de requisitos do instalador.
mautic_console() {
	mautic_compose exec -T -u www-data -w "$PA_MAUTIC_WORKDIR" mautic_web \
		php -d date.timezone=UTC bin/console "$@" >/dev/null 2>&1
}

# mautic_php_stdin [VARIAVEL=valor]...
#
# Roda, como www-data, um script PHP vindo do stdin desta função.
#
# Existe para escapar do inferno de aspas: o mesmo texto passaria
# por bash, ssh, docker exec, sh e php, e cada camada come uma
# barra invertida. Alimentar por stdin atravessa todas elas sem
# escape nenhum.
#
# Valor que vem de fora (idioma, fuso) entra por variável de
# ambiente, e o PHP lê com getenv(). Nunca colado dentro do código:
# até 2026-11-11 o idioma e o fuso eram interpolados no texto do
# script, e um --fuso com aspa simples virava código PHP executado
# no container e gravado no config/local.php. Achado da auditoria
# de segurança.
mautic_php_stdin() {
	local variaveis=() par

	for par in "$@"; do
		variaveis+=(-e "$par")
	done

	mautic_compose exec -T -u www-data -w "$PA_MAUTIC_WORKDIR" \
		${variaveis[@]+"${variaveis[@]}"} mautic_web php /dev/stdin
}

# mautic_corrigir_dono
#
# Devolve var/ inteiro para www-data, como root.
#
# É a recuperação de quem já rodou console como root e caiu no
# 500. Reparar o dono é melhor que apagar: o cache se refaz
# sozinho, e nada mais em var/ precisa morrer por causa disso.
mautic_corrigir_dono() {
	mautic_compose exec -T mautic_web \
		chown -R www-data:www-data "${PA_MAUTIC_WORKDIR}/var" >/dev/null 2>&1
}

# mautic_descartar_cache
#
# Tira o cache do caminho sem disputar a pasta com o site, como
# www-data. Mesmo comando da receita do credenciais.txt e do README.
#
# Por que não o cache:clear: medido em 2026-10-27, numa VPS de 2 GB
# com Mautic 7.2.2, ele levou 37 s e falhou com "Failed to remove
# directory var/cache/prod: Directory not empty". Enquanto ele
# apaga, o Apache continua atendendo (healthcheck, robôs no domínio
# público) e recria arquivos ali dentro. Rodado de novo à mão, parou
# no meio, deixou o cache em pedaços (prod, pro_ e pro~) e o site
# passou a responder 500.
#
# O mv é atômico: a pasta sai do caminho de uma vez, a próxima
# requisição monta outra do zero, e o rm apaga uma pasta que
# ninguém mais usa. O pro_ e o pro~ são sobras de um cache:clear
# interrompido.
mautic_descartar_cache() {
	# A expansão acontece dentro do container, não aqui.
	# shellcheck disable=SC2016
	mautic_compose exec -T -u www-data -w "${PA_MAUTIC_WORKDIR}/var/cache" mautic_web \
		sh -c 'mv prod "prod.descartar.$$" 2>/dev/null; rm -rf prod.descartar.* pro_ pro~' \
		>/dev/null 2>&1
}

# mautic_limpar_cache
#
# Sempre depois de mexer em config/local.php: o Mautic guarda a
# configuração compilada no cache, então gravar idioma ou fuso sem
# limpar não muda nada na tela. Foi exatamente o que fez o painel
# nascer em inglês com o idioma correto salvo.
#
# E sempre depois de recriar o container da web. A imagem traz um
# cache já compilado, de quando ela foi construída, sem site_url
# nenhum. Com ele o cookie de sessão sai sem a marca "secure", porque
# o Mautic decide isso na compilação, olhando se o site_url começa
# com https. Medido em 2026-11-11: depois de uma atualização, que
# recria o container, o cookie saía sem "secure"; refeito o cache,
# passou a sair com ela.
#
# Não recria o container: temas e plugins instalados pelo painel
# moram na camada dele (docroot/themes, docroot/plugins, vendor), e
# se perderiam. Logo depois de instalar não haveria o que perder,
# mas a função é a mesma da receita que a pessoa usa meses depois, e
# um caminho só é um caminho testado.
mautic_limpar_cache() {
	# O chown antes cobre o caso de o cache já ter sido sujado por
	# root em alguma execução anterior. Sem ele, o rm falha com
	# "Permission denied" nos arquivos de root.
	#
	# Ele não derruba a função: com o site no ar, um arquivo do cache
	# pode sumir no meio da varredura, e o chown sai com erro sem que
	# nada esteja errado. Num teste sob carga, em 2026-10-27, uma
	# rodada morreu calada aqui. Se o dono estiver mesmo errado, o rm
	# abaixo falha e o aviso sai.
	mautic_corrigir_dono || true

	if ! mautic_descartar_cache; then
		ui_aviso "Não consegui limpar o cache."
		ui_detalhe "O Mautic pode demorar a refletir idioma e fuso."
		ui_detalhe "A receita para fazer à mão está em ${PA_MAUTIC_CREDENCIAIS}."
		return 1
	fi

	# Reinicia só a web, para nada em memória sobreviver ao cache
	# novo. Cron e worker não precisam: processos curtos, e os
	# workers se renovam sozinhos a cada 5 minutos.
	mautic_compose restart mautic_web >/dev/null 2>&1 || true
	ui_aguardar_ate "Cache limpo; aguardando o Mautic voltar" 180 \
		mautic_container_saudavel mautic_web || return 1
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

# mautic_imagens_presentes
#
# Verdadeiro quando todas as imagens do compose já estão nesta
# máquina.
mautic_imagens_presentes() {
	local imagem
	while IFS= read -r imagem; do
		[[ -n "$imagem" ]] || continue
		docker image inspect "$imagem" >/dev/null 2>&1 || return 1
	done < <(mautic_compose config --images 2>/dev/null)
}

# mautic_baixar_imagens
#
# Baixa as imagens antes de subir qualquer coisa, com o progresso
# na tela. Até 2026-10-22 o download acontecia dentro do `up -d`,
# com a saída descartada: 626 MB do Mautic e 104 MB do MariaDB
# (comprimidos, Docker Hub, amd64) com a tela parada num "Subindo o
# banco de dados", o que convida ao Ctrl-C.
#
# Sem rede mas com as imagens já presentes, segue com aviso: o
# `up -d` usa o que está aqui.
mautic_baixar_imagens() {
	ui_passo "Baixando as imagens do Mautic e do banco"
	ui_detalhe "Cerca de 730 MB na primeira vez. Pode levar alguns minutos,"
	ui_detalhe "e o progresso aparece logo abaixo."

	if mautic_compose pull; then
		ui_ok "Imagens prontas"
		return 0
	fi

	if mautic_imagens_presentes; then
		ui_aviso "Não consegui conferir se há imagem mais nova; uso as que já estão aqui."
		return 0
	fi

	ui_fatal \
		"Não consegui baixar as imagens do Mautic." \
		"Nenhum container foi criado. Confira a conexão da VPS com" \
		"o Docker Hub e rode este instalador de novo. Para ver o erro:" \
		"" \
		"    cd ${PA_MAUTIC_DIR} && docker compose pull"
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
#
# Enquanto o Mautic não está instalado, ele sobe SEM rota no Traefik
# (PLAYAHEAD_PUBLICAR=false, lido pelo label traefik.enable do
# compose). Achado da auditoria de segurança de 2026-11-11: do
# instante em que o container sobe até o mautic:install terminar, o
# assistente web do Mautic respondia no domínio público, com os dados
# do banco já preenchidos pelas variáveis de ambiente. Quem chegasse
# primeiro criava o administrador, e há robôs que acompanham os
# registros públicos de certificados novos justamente para isso. A
# instalação inteira acontece por dentro do container, e a rota só é
# ligada depois, em mautic_subir_resto.
#
# Com --wizard não há como: quem conclui a instalação é a pessoa,
# pelo navegador. O aviso disso sai no main_instalar.
mautic_subir_web() {
	ui_passo "Subindo o Mautic"

	local publicar="true"
	if [[ "${PA_WIZARD:-0}" -eq 0 ]] && ! mautic_site_url_gravado; then
		publicar="false"
		ui_detalhe "Sem endereço público até a instalação terminar."
	fi

	PLAYAHEAD_PUBLICAR="$publicar" mautic_compose up -d mautic_web >/dev/null 2>&1 ||
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
#
# É também aqui que o Mautic ganha o endereço público: o `up -d` sem
# PLAYAHEAD_PUBLICAR recria o container da web com a rota do Traefik
# ligada (ver mautic_subir_web). Container recriado volta com o cache
# que veio na imagem, e por isso a limpeza de cache vem depois desta
# função, e não antes.
mautic_subir_resto() {
	ui_passo "Publicando o Mautic e subindo o agendador e os workers"

	mautic_compose up -d >/dev/null 2>&1 ||
		ui_fatal \
			"Falha ao subir cron e worker." \
			"O Mautic já está instalado; isto afeta campanhas e envios." \
			"Veja o log:" \
			"" \
			"    cd ${PA_MAUTIC_DIR} && docker compose logs mautic_cron"

	ui_aguardar_ate "Aguardando o Mautic responder" 300 \
		mautic_container_saudavel mautic_web ||
		ui_fatal \
			"O Mautic não voltou depois de ganhar o endereço público." \
			"Veja o log:" \
			"" \
			"    cd ${PA_MAUTIC_DIR} && docker compose logs mautic_web"

	ui_ok "Mautic, agendador e workers no ar"
}

# mautic_workers_com_limite
#
# Verdadeiro quando os workers vão encerrar sozinhos de tempos em
# tempos. Na instalação normal confere o processo em execução; com
# --wizard confere só o supervisord.conf, porque a imagem segura os
# workers até o assistente web terminar e ainda não há processo.
mautic_workers_com_limite() {
	if [[ "$PA_WIZARD" -eq 1 ]]; then
		mautic_compose exec -T mautic_worker \
			grep -q -- '--time-limit=' /etc/supervisor/conf.d/supervisord.conf
		return
	fi

	mautic_compose exec -T mautic_worker ps -eo args 2>/dev/null |
		grep -q -- 'messenger:consume email --time-limit='
}

# mautic_conferir_workers
#
# Segunda proteção do --time-limit acrescentado no entrypoint do
# mautic_worker (o motivo está no comentário dele, no compose).
#
# Aquela linha falha para o lado seguro: se uma versão nova da
# imagem mudar o supervisord.conf, ela não altera nada e o worker
# roda como antes. Só que "como antes" é o defeito medido em
# 2026-10-20: o SMTP trocado no painel não chega ao worker, o
# e-mail vai para o endereço antigo e o histórico do contato diz
# que foi enviado. Por isso a falha não pode ficar só no log do
# container, onde ninguém olha. Avisa e segue: o Mautic está no ar.
mautic_conferir_workers() {
	if ui_aguardar_ate "Conferindo se os workers releem a configuração" 90 \
		mautic_workers_com_limite; then
		return 0
	fi

	ui_aviso "Os workers subiram sem --time-limit."
	ui_detalhe "Sem ele, um SMTP trocado no painel só passa a valer"
	ui_detalhe "depois de reiniciar o worker:"
	ui_detalhe ""
	ui_detalhe "    cd ${PA_MAUTIC_DIR} && docker compose restart mautic_worker"
	ui_detalhe ""
	ui_detalhe "Causa provável: a imagem do Mautic mudou o supervisord.conf."
	ui_detalhe "    docker compose logs mautic_worker | grep playahead"
}

# ------------------------------------------------------------
# Conclusão da instalação
# ------------------------------------------------------------

# mautic_ja_instalado
#
# O teste B14 mostrou o sinal confiável: instalação concluída
# grava site_url no local.php. Antes disso o arquivo existe, mas
# só com parâmetros de banco.
# ------------------------------------------------------------
# Proxy confiável
# ------------------------------------------------------------

# mautic_gravar_proxies
#
# Sem este passo o site não abre: laço de redirecionamento.
#
# O Traefik termina o TLS e conversa com o Apache em HTTP,
# avisando por X-Forwarded-Proto que a conexão original era
# HTTPS. Para o Symfony acreditar nesse cabeçalho, alguém precisa
# ter chamado Request::setTrustedProxies(). Quem chama é o
# docroot/app/middlewares/TrustMiddleware.php, e ele lê a
# configuração pelo ConfigAwareTrait, que faz include de
# config/local.php e de config/parameters_local.php. E nada mais:
# não lê variável de ambiente nenhuma.
#
# Por isso o MAUTIC_TRUSTED_PROXIES do compose não resolve. Ele
# chega no container de injeção de dependência do Symfony, como
# json:resolve:MAUTIC_TRUSTED_PROXIES, mas esse parâmetro não é
# o que configura o HttpFoundation. Medido na VPS: com a variável
# no ambiente e o JSON válido, o ParameterLoader ainda devolvia
# trusted_proxies como array vazio.
#
# O resultado é o pior tipo de falha. O Mautic vê http, compara
# com o site_url https e devolve 301 para https; o navegador
# volta por https, o Traefik encaminha por http outra vez, e o
# laço nunca fecha. O log do Traefik fica limpo, porque o Traefik
# roteou certo.
#
# Gravar em parameters_local.php, e não em local.php, é
# deliberado. O ConfigAwareTrait mescla o parameters_local por
# cima do local, e este arquivo não é reescrito por ninguém: nem
# pelo mautic:install, nem pelo assistente web, nem pelo "salvar
# configuração" do painel, que reescrevem o local.php e não
# conhecem esta chave. Em local.php a correção sobreviveria à
# instalação e morreria no dia em que a pessoa salvasse qualquer
# ajuste na interface.
#
# Roda antes da instalação de propósito, para valer também no
# caminho do --wizard, onde o site_url só é gravado no fim.
# Verificado que não precisa de cache limpo: o middleware lê o
# arquivo a cada requisição.
mautic_gravar_proxies() {
	ui_passo "Autorizando o Traefik como proxy confiável"

	if ! mautic_php_stdin <<PHP
<?php
\$arquivo = 'config/parameters_local.php';
\$chave = "\t'trusted_proxies' => array('${PA_MAUTIC_PROXY_CONFIAVEL}'),\n";

if (!file_exists(\$arquivo)) {
    \$conteudo = '<?php' . "\n\n" . '\$parameters = array(' . "\n"
        . \$chave . ');' . "\n";

    exit(file_put_contents(\$arquivo, \$conteudo) === false ? 1 : 0);
}

\$texto = file_get_contents(\$arquivo);
if (\$texto === false) {
    exit(1);
}

if (preg_match("/'trusted_proxies'\s*=>/", \$texto)) {
    exit(0);
}

\$novo = preg_replace(
    '/\n\);\s*\$/',
    "\n" . \$chave . ");\n",
    \$texto,
    1,
    \$trocas
);

exit((\$trocas === 0 || file_put_contents(\$arquivo, \$novo) === false) ? 1 : 0);
PHP
	then
		ui_erro "Não consegui autorizar o Traefik como proxy confiável."
		ui_vazio
		ui_info "Sem isso o domínio entra em laço de redirecionamento, e"
		ui_info "o navegador mostra ERR_TOO_MANY_REDIRECTS."
		ui_vazio
		ui_info "Para fazer à mão, crie o arquivo dentro do container:"
		ui_detalhe "cd ${PA_MAUTIC_DIR}"
		ui_detalhe "docker compose exec -u www-data mautic_web \\"
		ui_detalhe "  nano config/parameters_local.php"
		ui_vazio
		ui_info "com este conteúdo:"
		ui_detalhe "<?php"
		ui_detalhe "\$parameters = array("
		ui_detalhe "  'trusted_proxies' => array('${PA_MAUTIC_PROXY_CONFIAVEL}'),"
		ui_detalhe ");"
		ui_vazio
		return 1
	fi

	ui_ok "Proxy confiável gravado em config/parameters_local.php"
}

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
#
#   sync-metadata-storage  Cria a tabela `migrations` antes da
#                          instalação. O último passo do
#                          mautic:install (InstallService::
#                          finalMigrationStep) roda
#                          `doctrine:migrations:version --add --all`
#                          para marcar as 104 migrações como já
#                          feitas, mas a tabela não existe nessa
#                          hora: o comando falha com "The metadata
#                          storage is not initialized", e o
#                          instalador descarta a saída sem conferir.
#                          A instalação termina com sucesso e com
#                          as 104 pendentes.
#
#                          O preço aparece na primeira vez que a
#                          web reinicia, num reboot ou numa troca
#                          de imagem: o entrypoint da imagem roda
#                          `doctrine:migrations:migrate`. Medido em
#                          2026-10-20: 84 migrações puladas por
#                          pré-checagem, que continuam pendentes e
#                          voltam a ser checadas a cada subida
#                          (cerca de 40 s com o site em 404), e 11
#                          que rodaram 51 comandos SQL num banco já
#                          atualizado, entre eles conversão de
#                          charset e recriação de índices. Numa
#                          base com meses de contatos, isso roda
#                          durante a subida.
#
#                          A imagem oficial faz a mesma coisa no
#                          caminho dela de dados de teste: sync
#                          antes do mautic:install.
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

	if ! mautic_console doctrine:migrations:sync-metadata-storage; then
		ui_fatal \
			"Não consegui preparar a tabela de migrações do banco." \
			"Nada foi derrubado. Para ver o erro completo:" \
			"" \
			"    cd ${PA_MAUTIC_DIR}" \
			"    docker compose exec -u www-data -w ${PA_MAUTIC_WORKDIR} \\" \
			"      mautic_web php bin/console doctrine:migrations:sync-metadata-storage"
	fi

	if ! mautic_console mautic:install \
		--admin_firstname="$PA_MAUTIC_ADMIN_NOME" \
		--admin_lastname="$PA_MAUTIC_ADMIN_SOBRENOME" \
		--admin_email="$email_admin" \
		--admin_password="$PA_MAUTIC_SENHA_ADMIN" \
		--force \
		"https://${dominio}"; then

		ui_fatal \
			"A instalação do Mautic falhou." \
			"Nada foi derrubado. Para ver o erro completo:" \
			"" \
			"    cd ${PA_MAUTIC_DIR}" \
			"    docker compose exec -u www-data -w ${PA_MAUTIC_WORKDIR} \\" \
			"      mautic_web php -d date.timezone=UTC \\" \
			"      bin/console mautic:install --force https://${dominio}"
	fi

	ui_ok "Instalação concluída"

	# O mautic:install não confere o passo das migrações, então a
	# conferência fica aqui. Avisa e segue: o Mautic funciona, e o
	# problema só aparece na próxima subida da web.
	if mautic_console doctrine:migrations:up-to-date; then
		ui_ok "Migrações do banco registradas"
	else
		ui_aviso "Ficaram migrações do banco sem registro."
		ui_detalhe "Na próxima vez que a web reiniciar, ela vai tentar"
		ui_detalhe "aplicá-las de novo. Para conferir:"
		ui_detalhe ""
		ui_detalhe "    cd ${PA_MAUTIC_DIR}"
		ui_detalhe "    docker compose exec -u www-data -w ${PA_MAUTIC_WORKDIR} \\"
		ui_detalhe "      mautic_web php bin/console doctrine:migrations:status"
	fi
}

# ------------------------------------------------------------
# Idioma e configuração regional
#
# O Mautic nasce em inglês e com o fuso que o processo do
# instalador usou. Os dois se resolvem depois da instalação, e os
# dois precisam de cache limpo para aparecer na tela.
# ------------------------------------------------------------

# mautic_idioma_existe <codigo>
#
# Confere o código contra o manifesto oficial antes de baixar, só
# para a mensagem de erro poder ser específica. Manifesto fora do
# ar não impede nada: o download seguinte fala por si.
mautic_idioma_existe() {
	local codigo="$1"

	local manifesto
	manifesto="$(curl -fsSL --max-time 20 "$PA_MAUTIC_LANG_MANIFEST" 2>/dev/null || true)"

	[[ -n "$manifesto" ]] || return 0

	printf '%s' "$manifesto" | grep -qF "\"locale\": \"${codigo}\""
}

# mautic_instalar_idioma <codigo>
#
# Baixa e extrai o pacote de idioma.
#
# Tudo acontece dentro do container e como www-data, de propósito:
# `unzip` não existe no Ubuntu limpo, mas a imagem tem PHP com
# ZipArchive; e extrair como www-data já deixa o dono certo, sem
# um chown depois. O zip oficial já vem com o diretório do idioma
# na raiz, então extrair em translations/ basta.
#
# Falha aqui é aviso, não erro: o Mautic funciona em inglês.
mautic_instalar_idioma() {
	local codigo="$1"

	case "$codigo" in
		en | en_US)
			ui_ok "Idioma inglês: o Mautic já vem com ele"
			return 0
			;;
	esac

	ui_passo "Instalando o idioma ${codigo}"
	ui_detalhe "O pacote vem de language-packs.mautic.com, o servidor de"
	ui_detalhe "idiomas do Mautic. Nada desta máquina é enviado."

	if ! mautic_idioma_existe "$codigo"; then
		ui_aviso "\"${codigo}\" não está na lista oficial de idiomas."
		ui_detalhe "Veja os códigos válidos em ${PA_MAUTIC_LANG_MANIFEST}"
		ui_detalhe "Seguindo em inglês."
		return 1
	fi

	# Nome com um trecho aleatório: o /tmp do container é de todos os
	# processos dele, e um nome fixo poderia ser ocupado antes.
	local zip
	zip="/tmp/pa-idioma.$(openssl rand -hex 8).zip"

	if ! mautic_compose exec -T -u www-data mautic_web \
		curl -fsSL --max-time 90 -o "$zip" \
		"${PA_MAUTIC_LANG_BASE}${codigo}.zip" >/dev/null 2>&1; then

		ui_aviso "Não consegui baixar o pacote de idioma ${codigo}."
		ui_detalhe "Seguindo em inglês. Dá para instalar depois pelo painel,"
		ui_detalhe "em Configurações."
		return 1
	fi

	# Antes de extrair, confere o que o zip traz. O pacote oficial só
	# tem uma pasta, com o código do idioma. Um zip com outra coisa
	# (um .htaccess na raiz, um caminho com "..") poderia desligar a
	# proteção de docroot/translations ou gravar fora dela, então é
	# recusado inteiro.
	if ! mautic_php_stdin "PA_ZIP=${zip}" "PA_IDIOMA=${codigo}" <<'PHP' >/dev/null 2>&1; then
<?php
$zip = new ZipArchive();
if ($zip->open(getenv('PA_ZIP')) !== true) {
    exit(1);
}
$pasta = getenv('PA_IDIOMA') . '/';
for ($i = 0; $i < $zip->numFiles; $i++) {
    $nome = $zip->getNameIndex($i);
    if ($nome === false
        || strncmp($nome, $pasta, strlen($pasta)) !== 0
        || strpos($nome, '..') !== false
        || strpos($nome, '\\') !== false
        || strtolower(basename($nome)) === '.htaccess') {
        exit(1);
    }
}
$ok = $zip->extractTo('docroot/translations/');
$zip->close();
exit($ok ? 0 : 1);
PHP
		ui_aviso "Baixei o pacote de idioma mas não consegui extrair."
		ui_detalhe "Seguindo em inglês."
		mautic_compose exec -T -u www-data mautic_web \
			rm -f "$zip" >/dev/null 2>&1 || true
		return 1
	fi

	mautic_compose exec -T -u www-data mautic_web \
		rm -f "$zip" >/dev/null 2>&1 || true

	ui_ok "Idioma ${codigo} instalado"
}

# mautic_gravar_config <idioma> <fuso>
#
# Grava idioma e fuso no config/local.php.
#
# O fuso precisa deste passo por causa do contorno do instalador:
# ele roda com `-d date.timezone=UTC` para passar na checagem de
# requisitos, e o Mautic guarda esse UTC como fuso padrão da
# aplicação. Sem corrigir depois, horário de campanha e relatório
# saem em UTC.
#
# A edição é por substituição no texto, não por include e
# var_export: o local.php guarda a senha do banco e outras chaves
# que não têm por que passar por um round-trip. Chave ausente é
# inserida antes do fecho do array.
mautic_gravar_config() {
	local idioma="$1"
	local fuso="$2"

	ui_passo "Gravando idioma e fuso na configuração"

	# Heredoc citado: nada do bash entra no texto do PHP. O idioma e
	# o fuso chegam por variável de ambiente, e o próprio PHP recusa o
	# que não tiver cara de código de idioma e de fuso, para o valor
	# nunca virar outra coisa dentro do local.php.
	if ! mautic_php_stdin "PA_IDIOMA=${idioma}" "PA_FUSO=${fuso}" <<'PHP'
<?php
$arquivo = 'config/local.php';
$valores = [
    'locale'           => (string) getenv('PA_IDIOMA'),
    'default_timezone' => (string) getenv('PA_FUSO'),
];

foreach ($valores as $valor) {
    if (!preg_match('/^[A-Za-z0-9_+\/-]{2,64}$/', $valor)) {
        exit(1);
    }
}

$texto = file_get_contents($arquivo);
if ($texto === false) {
    exit(1);
}

foreach ($valores as $chave => $valor) {
    $padrao = "/('" . preg_quote($chave, '/') . "'\s*=>\s*)'[^']*'/";
    $novo = preg_replace_callback(
        $padrao,
        function ($m) use ($valor) {
            return $m[1] . "'" . $valor . "'";
        },
        $texto,
        1,
        $trocas
    );

    if ($trocas > 0) {
        $texto = $novo;
        continue;
    }

    $linha = "\n\t'" . $chave . "' => '" . $valor . "',\n);\n";
    $texto = preg_replace_callback(
        '/\n\);\s*$/',
        function () use ($linha) {
            return $linha;
        },
        $texto,
        1,
        $trocas
    );

    if ($trocas === 0) {
        exit(1);
    }
}

exit(file_put_contents($arquivo, $texto) === false ? 1 : 0);
PHP
	then
		ui_aviso "Não consegui gravar idioma e fuso na configuração."
		ui_detalhe "O Mautic funciona, mas em inglês e com fuso UTC."
		ui_detalhe "Ajuste no painel, em Configurações."
		return 1
	fi

	ui_ok "Idioma ${idioma} e fuso ${fuso} gravados"
}

# mautic_regionalizar <idioma> <fuso>
#
# Pacote de idioma e configuração. Os dois só aparecem na tela depois
# de o cache ser refeito, e isso fica para o main_instalar, depois de
# o container ganhar o endereço público: recriar o container devolve
# o cache que veio na imagem, e limpar antes seria trabalho perdido.
mautic_regionalizar() {
	local idioma="$1"
	local fuso="$2"

	mautic_instalar_idioma "$idioma" || idioma="en_US"
	mautic_gravar_config "$idioma" "$fuso" || true
}

# ------------------------------------------------------------
# Versão do Mautic
# ------------------------------------------------------------

# mautic_versao_da_imagem <imagem>
#
# mautic/mautic:7.2.2-apache vira 7.2.2.
mautic_versao_da_imagem() {
	local tag="${1##*:}"
	printf '%s\n' "${tag%-apache}"
}

# mautic_consultar_mais_nova
#
# Ecoa a tag mais nova da linha 7 (ex.: 7.2.3-apache), ou nada.
#
# O filtro é ancorado, e não "começa com 7": existem tags como
# 7.2.2-20261026-apache e 7.0.0-beta-apache, que não são versões a
# oferecer. A ordem é por número de versão (sort -V), e não pela
# data, porque uma 7.1.x reconstruída hoje teria data mais nova que
# a 7.2.2. Nunca a tag latest: um dia ela pula para o Mautic 8.
#
# O JSON é lido com grep, porque jq não vem no Ubuntu limpo. Se o
# formato mudar, o grep não acha nada e a função ecoa vazio, que é
# o mesmo caminho de uma consulta que falhou.
mautic_consultar_mais_nova() {
	curl -fsS --max-time 5 "$PA_MAUTIC_HUB_TAGS" 2>/dev/null |
		grep -o '"name": *"[^"]*"' |
		sed -E 's/"name": *"([^"]*)"/\1/' |
		grep -E '^7\.[0-9]+\.[0-9]+-apache$' |
		sort -V | tail -n 1 || true
}

# mautic_versao_maior <a> <b>
#
# Verdadeiro quando a é mais nova que b.
mautic_versao_maior() {
	[[ "$1" != "$2" ]] &&
		[[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" == "$1" ]]
}

# mautic_escolher_versao
#
# Política de versões do CLAUDE.md: recomendada (testada, padrão do
# Enter) ou mais nova da mesma linha (sem teste, por conta da
# pessoa). A consulta ao Docker Hub é anunciada na tela, como as
# outras consultas a terceiros do script. Consulta falhando ou sem
# versão mais nova, não há pergunta e a recomendada segue.
mautic_escolher_versao() {
	local recomendada nova tag
	recomendada="$(mautic_versao_da_imagem "$PA_MAUTIC_IMAGEM_RECOMENDADA")"

	ui_vazio
	ui_info "Consultando o Docker Hub (hub.docker.com) para ver se há Mautic 7"
	ui_info "mais novo que o ${recomendada}, a versão testada pela Play Ahead."
	ui_detalhe "Só lê a lista pública de versões; nada desta máquina é enviado."

	tag="$(mautic_consultar_mais_nova)"

	if [[ -z "$tag" ]]; then
		ui_aviso "Não consegui consultar o Docker Hub; fica a versão recomendada."
		[[ "$PA_MAUTIC_VERSAO_FLAG" == "mais-nova" ]] &&
			ui_detalhe "O --versao=mais-nova não tem efeito sem a consulta."
		PA_MAUTIC_VERSAO_ESCOLHA="recomendada"
		return 0
	fi

	nova="$(mautic_versao_da_imagem "$tag")"

	if ! mautic_versao_maior "$nova" "$recomendada"; then
		ui_ok "A versão recomendada (${recomendada}) é a mais nova da linha 7"
		PA_MAUTIC_VERSAO_ESCOLHA="recomendada"
		return 0
	fi

	local escolha="${PA_MAUTIC_VERSAO_FLAG:-}"

	if [[ -z "$escolha" ]]; then
		if ! ui_interativo; then
			escolha="recomendada"
		else
			local opcao_recomendada="Recomendada: Mautic ${recomendada}, testada pela Play Ahead"
			local opcao_nova="Mais nova: Mautic ${nova}, sem teste, por sua conta"
			# O nome não pode ser "resposta": o ui_escolher recebe a
			# variável por referência e tem uma local com esse nome, e
			# a escolha iria para a dele. Medido: a opção 2 voltava 1.
			local versao_escolhida=""
			ui_escolher versao_escolhida "Qual versão do Mautic instalar?" \
				"$opcao_recomendada" "$opcao_nova"
			escolha="recomendada"
			[[ "$versao_escolhida" == "$opcao_nova" ]] && escolha="mais-nova"
		fi
	fi

	PA_MAUTIC_VERSAO_ESCOLHA="$escolha"

	if [[ "$escolha" == "mais-nova" ]]; then
		PA_MAUTIC_IMAGEM="mautic/mautic:${tag}"
		ui_aviso "Mautic ${nova} não passou pelo teste da Play Ahead."
		ui_detalhe "Se algo der errado, a versão testada é a ${recomendada}."
	else
		ui_ok "Fica a versão recomendada, ${recomendada}"
		ui_detalhe "Existe a ${nova}, ainda sem teste da Play Ahead."
	fi
}

# mautic_compose_definir_imagem
#
# Troca o padrão da imagem do Mautic no compose instalado pela
# escolhida, quando ela não é a recomendada. Mesmo jeito do
# certresolver: o template não muda, e o build segue conferindo o
# embutido byte a byte. Para se não achar o padrão, em vez de
# instalar uma versão e anunciar outra.
mautic_compose_definir_imagem() {
	[[ "$PA_MAUTIC_IMAGEM" != "$PA_MAUTIC_IMAGEM_RECOMENDADA" ]] || return 0

	local antes="\${MAUTIC_IMAGE:-${PA_MAUTIC_IMAGEM_RECOMENDADA}}"
	local depois="\${MAUTIC_IMAGE:-${PA_MAUTIC_IMAGEM}}"

	grep -qF -- "$antes" "$PA_MAUTIC_COMPOSE" ||
		ui_fatal \
			"Não achei a imagem recomendada no compose para trocar." \
			"Sinal de que o template mudou e esta função não acompanhou."

	sed -i "s|${antes//\$/\\\$}|${depois//\$/\\\$}|g" "$PA_MAUTIC_COMPOSE"

	if grep -qF -- "$antes" "$PA_MAUTIC_COMPOSE" ||
		! grep -qF -- "$depois" "$PA_MAUTIC_COMPOSE"; then
		ui_fatal \
			"Não consegui trocar a imagem do Mautic no compose." \
			"Confira ${PA_MAUTIC_COMPOSE} antes de rodar de novo."
	fi
}

# mautic_descrever_versao
#
# Uma linha para o resumo, o bloco final e o credenciais.txt.
mautic_descrever_versao() {
	local versao
	versao="$(mautic_versao_da_imagem "$PA_MAUTIC_IMAGEM")"
	case "$PA_MAUTIC_VERSAO_ESCOLHA" in
		mais-nova) printf '%s (mais nova, sem teste da Play Ahead)\n' "$versao" ;;
		em-andamento) printf '%s (a da instalação em andamento)\n' "$versao" ;;
		*) printf '%s (recomendada, testada pela Play Ahead)\n' "$versao" ;;
	esac
}

# ------------------------------------------------------------
# Saída SMTP
# ------------------------------------------------------------

# Host do Amazon SES usado só para abrir a conexão. Qualquer região
# serve: o que se mede é se o provedor da VPS deixa a porta sair.
PA_SMTP_HOST_TESTE="email-smtp.us-east-1.amazonaws.com"

# Preenchidos por mautic_testar_smtp: aberta, bloqueada ou
# desconhecida (sem DNS, não deu para testar).
PA_SMTP_587=""
PA_SMTP_2587=""

# mautic_porta_sai <host> <porta>
#
# Só abre a conexão TCP e fecha. Nada é enviado. Usa o /dev/tcp do
# bash porque nc e telnet não são garantidos no Ubuntu limpo.
#
# Medido na DigitalOcean em 2026-10-20: a porta bloqueada não
# recusa, simplesmente não responde, e por isso o timeout é o que
# decide. A aberta conecta na hora.
mautic_porta_sai() {
	local host="$1"
	local porta="$2"

	timeout 5 bash -c "exec 3<>/dev/tcp/${host}/${porta}" 2>/dev/null
}

# mautic_testar_smtp
#
# A DigitalOcean bloqueia a saída nas portas 25, 465 e 587, que são
# as que todo tutorial de SMTP manda usar. O painel do Mautic aceita
# a configuração, o envio falha, e o histórico do contato diz "Email
# Enviado". O SES também atende nas portas 2587 (STARTTLS) e 2465,
# que passam. Medido na VPS de teste: 25, 465 e 587 sem resposta;
# 2465 e 2587 abertas.
#
# O script não configura SMTP (ver "Fora de escopo" no CLAUDE.md).
# Ele só mede e diz qual porta usar, porque esta é a primeira coisa
# que a pessoa vai fazer depois de instalar, e a falha é silenciosa.
#
# A conexão vai a um servidor da Amazon, e isso é dito na tela: a
# documentação promete que o script não envia nada sem avisar.
mautic_testar_smtp() {
	ui_passo "Testando a saída de e-mail (SMTP) desta VPS"
	ui_detalhe "Só abre uma conexão com ${PA_SMTP_HOST_TESTE},"
	ui_detalhe "o servidor do Amazon SES, e fecha. Nada é enviado."

	if ! getent hosts "$PA_SMTP_HOST_TESTE" >/dev/null 2>&1; then
		PA_SMTP_587="desconhecida"
		PA_SMTP_2587="desconhecida"
		ui_aviso "Não consegui resolver ${PA_SMTP_HOST_TESTE}; teste pulado."
		return 0
	fi

	PA_SMTP_587="bloqueada"
	PA_SMTP_2587="bloqueada"
	mautic_porta_sai "$PA_SMTP_HOST_TESTE" 587 && PA_SMTP_587="aberta"
	mautic_porta_sai "$PA_SMTP_HOST_TESTE" 2587 && PA_SMTP_2587="aberta"

	if [[ "$PA_SMTP_587" == "aberta" ]]; then
		ui_ok "Saída pela porta 587 liberada"
		return 0
	fi

	if [[ "$PA_SMTP_2587" == "aberta" ]]; then
		ui_aviso "Esta VPS não consegue sair pela porta 587."
		ui_detalhe "É bloqueio do provedor (a DigitalOcean bloqueia 25, 465 e 587)."
		ui_detalhe "No Amazon SES, use a porta 2587 (STARTTLS) no painel do Mautic."
		return 0
	fi

	ui_aviso "Esta VPS não consegue sair nem pela porta 587 nem pela 2587."
	ui_detalhe "Nenhum envio por SMTP vai funcionar daqui. Peça ao provedor"
	ui_detalhe "a liberação da saída SMTP antes de configurar o e-mail."
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

		printf 'VERSÃO\n'
		printf '  Mautic %s\n' "$(mautic_descrever_versao)"
		printf '  imagem: %s\n' "$PA_MAUTIC_IMAGEM"
		printf '  banco:  %s\n' "$PA_MARIADB_IMAGEM"
		printf '  instalador: %s %s\n' "$PA_FERRAMENTA" "$PA_VERSAO"
		[[ -n "$PA_MAUTIC_NOTA_ATUALIZACAO" ]] &&
			printf '  %s\n' "$PA_MAUTIC_NOTA_ATUALIZACAO"
		printf '\n'

		printf 'ADMIN\n'
		printf '  e-mail: %s\n' "$email_admin"
		if [[ -n "$PA_MAUTIC_SENHA_ADMIN" ]]; then
			printf '  senha:  %s\n' "$PA_MAUTIC_SENHA_ADMIN"
		elif [[ "${PA_WIZARD:-0}" -eq 1 ]]; then
			printf '  senha:  (a que você definir no assistente web)\n'
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

		printf '\n'
		printf '============================================================\n'
		printf ' E-MAIL (SMTP)\n'
		printf '============================================================\n\n'
		printf 'Saída desta VPS, medida na instalação:\n'
		printf '  porta 587:  %s\n' "${PA_SMTP_587:-não testada}"
		printf '  porta 2587: %s\n\n' "${PA_SMTP_2587:-não testada}"
		printf 'Vários provedores bloqueiam a saída nas portas 25, 465 e\n'
		printf '587; a DigitalOcean é um deles. No Amazon SES, com a 587\n'
		printf 'bloqueada, use a porta 2587 (STARTTLS) ou a 2465 (TLS).\n\n'
		printf 'Depois de alterar a configuração de e-mail no painel, os\n'
		printf 'workers que fazem o envio passam a usá-la em até 5 minutos,\n'
		printf 'sozinhos. Para valer na hora:\n\n'
		printf '  cd %s\n' "$PA_MAUTIC_DIR"
		printf '  docker compose restart mautic_worker\n\n'
		printf 'Confira o envio pelo log, não pelo histórico do contato: o\n'
		printf 'Mautic marca "Email Enviado" mesmo quando o servidor de\n'
		printf 'e-mail recusou. O log fica em:\n\n'
		printf '  docker compose exec mautic_web ls /var/www/html/var/logs\n'

		printf '\n'
		printf '============================================================\n'
		printf ' LIMPAR O CACHE\n'
		printf '============================================================\n\n'
		printf 'Limpar cache é a primeira coisa que se tenta quando algo\n'
		printf 'estranho acontece. Faça num horário de pouco movimento\n'
		printf '(o site sai do ar por menos de um minuto), nesta ordem:\n\n'
		printf '  cd %s\n' "$PA_MAUTIC_DIR"
		printf '  docker compose exec mautic_web \\\n'
		printf '    chown -R www-data:www-data /var/www/html/var\n'
		printf '  docker compose exec -u www-data -w /var/www/html/var/cache \\\n'
		# As aspas simples são do comando que a pessoa vai colar.
		# shellcheck disable=SC2016
		printf '    mautic_web sh -c %s\n' "'mv prod prod.velho; rm -rf prod.velho pro_ pro~'"
		printf '  docker compose restart mautic_web\n\n'
		printf 'O primeiro comando devolve os arquivos para o www-data (só\n'
		printf 'root consegue). O segundo tira o cache do caminho de uma\n'
		printf 'vez e o apaga, como www-data. O terceiro reinicia o site,\n'
		printf 'que monta um cache novo sozinho em menos de um minuto.\n\n'
		printf 'Não use o cache:clear. Medido: com o site no ar, ele disputa\n'
		printf 'a pasta com o próprio Mautic, falha no meio e pode deixar o\n'
		printf 'site em erro 500.\n\n'
		printf 'Não recrie o container para limpar o cache (up -d com\n'
		printf '%s): temas e plugins instalados pelo painel\n' "--force-recreate"
		printf 'moram dentro dele e se perderiam.\n\n'
		printf 'Comando de console (php bin/console) vai SEMPRE com\n'
		printf '%s. Sem ele o comando roda como root, deixa arquivos\n' "-u www-data"
		printf 'de root no cache, e o Mautic passa a responder 500. Foi\n'
		printf 'medido: 30.737 arquivos de root e o site fora do ar. Se isso\n'
		printf 'já aconteceu, a receita acima também recupera.\n'
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
# silencioso: o container sobe, o Mautic funciona, e o domínio não
# serve o Mautic.
#
# SEGUE OS REDIRECIONAMENTOS ATÉ O FIM, e só aceita 200 numa
# página que é reconhecidamente do Mautic.
#
# A versão anterior aceitava 301 e 302 como "roteamento correto", e
# isso custou caro em 2026-09-30: o domínio estava em laço de
# redirecionamento, o site não abria em navegador nenhum, e o
# script declarou sucesso. Um 301 não diz que deu certo, diz só
# que alguém respondeu. Para onde ele aponta é que importa, e o
# destino pode ser o mesmo endereço.
#
# Não derruba nada em caso de falha. Imprime o estado e como
# corrigir, conforme a regra de não haver rollback.
mautic_verificar_roteamento() {
	local dominio="$1"

	ui_passo "Conferindo se o domínio abre o Mautic"

	# Sem plano B com nome fixo em /tmp: um nome previsível, gravado
	# por root, é convite para link simbólico. Sem arquivo temporário
	# não há conferência, e isso é dito.
	local corpo
	if ! corpo="$(mktemp)"; then
		ui_aviso "Não consegui criar um arquivo temporário para a conferência."
		ui_detalhe "Costuma ser disco cheio. Abra no navegador: https://${dominio}"
		return 1
	fi

	local codigo="" url_final="" saltos="" medida=""
	local rc=0
	local lacos=0
	local _tentativa

	for _tentativa in $(seq 1 20); do
		rc=0

		# -L segue os redirecionamentos. O --max-redirs 10 é o que
		# transforma um laço infinito em resposta: o curl para e
		# sai com 47, e é assim que o laço fica detectável.
		medida="$(
			curl -skL --max-redirs 10 --max-time 20 \
				-o "$corpo" \
				-w '%{http_code}|%{url_effective}|%{num_redirects}' \
				"https://${dominio}/" 2>/dev/null
		)" || rc="$?"

		codigo="${medida%%|*}"
		saltos="${medida##*|}"
		url_final="${medida#*|}"
		url_final="${url_final%|*}"

		# 47 é "Maximum (10) redirects followed". Laço não se
		# resolve com o tempo, então duas medidas bastam: a
		# primeira pode pegar a aplicação ainda subindo.
		if [[ "$rc" -eq 47 ]]; then
			lacos=$((lacos + 1))
			[[ "$lacos" -ge 2 ]] && break
			sleep 6
			continue
		fi

		if [[ "$codigo" == "200" ]] &&
			mautic_pagina_do_mautic "$url_final" "$corpo"; then

			rm -f "$corpo"
			ui_ok "O domínio abre o Mautic"
			ui_detalhe "terminou em ${url_final}, com 200"
			[[ "${saltos:-0}" -gt 0 ]] &&
				ui_detalhe "depois de ${saltos} redirecionamento(s)"

			# A medida acima usa -k para classificar; o certificado
			# é conferido à parte, só agora que o Mautic respondeu.
			traefik_conferir_certificado "$dominio" "$url_final"
			return
		fi

		sleep 6
	done

	local trecho=""
	if [[ -s "$corpo" ]]; then
		trecho="$(tr -d '\000-\037' <"$corpo" | head -c 60)"
	fi
	rm -f "$corpo"

	# ----- laço de redirecionamento -----
	if [[ "$lacos" -ge 2 ]]; then
		ui_erro "O domínio entra em laço de redirecionamento."
		ui_vazio
		ui_info "No navegador isso aparece como ERR_TOO_MANY_REDIRECTS."
		ui_info "O Traefik roteou certo; quem redireciona é o Mautic."
		ui_vazio
		ui_info "Quase sempre é o proxy confiável: o Mautic não sabe"
		ui_info "que a conexão era HTTPS, compara com o site_url e"
		ui_info "manda de volta para HTTPS, sem fim."
		ui_vazio
		ui_info "Confira se o arquivo tem a chave:"
		ui_detalhe "cd ${PA_MAUTIC_DIR}"
		ui_detalhe "docker compose exec -u www-data mautic_web \\"
		ui_detalhe "  cat config/parameters_local.php"
		ui_vazio
		ui_info "Ele precisa conter:"
		ui_detalhe "'trusted_proxies' => array('${PA_MAUTIC_PROXY_CONFIAVEL}'),"
		ui_vazio
		ui_info "Faltando, rode este instalador de novo: ele grava a"
		ui_info "chave e não reinstala nada por cima."
		ui_vazio
		return 1
	fi

	# ----- 404: o Traefik atendeu e não achou o roteador -----
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

	# ----- 200, mas a página não é do Mautic -----
	if [[ "$codigo" == "200" ]]; then
		ui_aviso "O domínio respondeu 200, mas a página não é do Mautic."
		ui_detalhe "terminou em: ${url_final}"
		[[ -n "$trecho" ]] && ui_detalhe "começa com: ${trecho}"
		ui_vazio
		ui_info "Costuma ser outro site respondendo por este domínio, ou"
		ui_info "o DNS apontando para outro servidor. O Mautic em si"
		ui_info "está no ar dentro da máquina."
		ui_vazio
		return 1
	fi

	# ----- qualquer outra coisa -----
	ui_aviso "O domínio respondeu ${codigo:-nada} em vez de 200."
	[[ -n "$url_final" ]] && ui_detalhe "terminou em: ${url_final}"
	ui_detalhe "O Mautic está no ar dentro da máquina."
	ui_detalhe "Pode ser propagação de DNS ou emissão de certificado,"
	ui_detalhe "que às vezes levam alguns minutos. Tente abrir no"
	ui_detalhe "navegador daqui a pouco: https://${dominio}"
	ui_vazio

	return 1
}

# mautic_pagina_do_mautic <url_final> <arquivo_do_corpo>
#
# Um 200 sozinho não prova nada. O Traefik pode estar servindo
# outro site no mesmo domínio, e um DNS apontado para o servidor
# errado também devolve 200 de outra coisa. Por isso o teste olha
# onde a navegação parou e o que veio no corpo.
#
# São dois destinos legítimos:
#
#   /s/login      instalação concluída, sem sessão. Medido na VPS:
#                 a raiz devolve 302 para /s/dashboard, que devolve
#                 302 para /s/login, que devolve 200.
#   installer     caminho do --wizard, em que a instalação fica
#                 deliberadamente pela metade.
#
# O marcador do corpo é o campo de usuário do formulário de login.
# Procurar a palavra "Mautic" não serviria: ela aparece em
# qualquer página de erro da aplicação, inclusive na de 500.
mautic_pagina_do_mautic() {
	local url="$1"
	local corpo="$2"

	case "$url" in
		*installer*) return 0 ;;
	esac

	[[ -s "$corpo" ]] || return 1

	case "$url" in
		*/s/*)
			grep -q '_username' "$corpo" 2>/dev/null && return 0
			;;
	esac

	return 1
}
