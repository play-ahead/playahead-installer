#!/usr/bin/env bash
# shellcheck shell=bash
#
# ============================================================
# lib/mautic_atualizar.sh
# Modo de atualização do Mautic:
#
#     sudo bash mautic7.sh --atualizar
#
# Leva uma instalação concluída para a versão recomendada deste
# instalador. Nunca para a mais nova, e nunca sozinho: é ação
# pedida, com confirmação na tela.
#
# A ordem é a da regra de ouro do projeto, nada destrutivo:
#
#   1. confere a instalação e diz o que vai mudar;
#   2. baixa as imagens novas, com o site ainda no ar;
#   3. para o Mautic e faz o backup: banco, compose, .env,
#      configuração e os temas e plugins instalados pelo painel;
#   4. só então regrava o compose e sobe a versão nova, que aplica
#      as migrações do banco sozinha;
#   5. confere o resultado e diz onde o backup ficou.
#
# Não há volta automática. A migração do banco não desfaz, e um
# script que tentasse restaurar sozinho no meio de uma falha teria
# de adivinhar em que ponto a falha parou. Em vez disso, qualquer
# saída com erro depois do backup mostra os comandos para restaurar
# e o comando para continuar.
#
# ESTE É O ÚNICO PONTO DO PROJETO QUE SOBRESCREVE O COMPOSE. O
# motivo: a versão recomendada mora no template, e é o único caminho
# para uma instalação antiga receber as correções do compose (o
# --time-limit dos workers, a rotação de log). O compose antigo vai
# para o backup antes. O .env continua nunca sendo sobrescrito.
# ============================================================

# 1 quando o script foi chamado com --atualizar.
PA_ATUALIZAR=0

PA_MAUTIC_BACKUPS="${PA_MAUTIC_DIR}/backups"

# Existe do fim do backup até o fim da atualização. Guarda a pasta
# do backup e as versões de antes, para uma segunda execução seguir
# de onde a primeira parou em vez de fazer outro backup, já de um
# banco pela metade.
PA_MAUTIC_ATUALIZANDO="${PA_MAUTIC_DIR}/.atualizacao-em-andamento"

# O compose novo é gerado aqui, comparado com o instalado, e só vai
# para o lugar depois do backup.
PA_MAUTIC_COMPOSE_NOVO="${PA_MAUTIC_COMPOSE}.novo"

PA_MAUTIC_DOCROOT="${PA_MAUTIC_WORKDIR}/docroot"

# Preenchidas no planejamento.
PA_MAUTIC_BACKUP=""
PA_MAUTIC_VERSAO_DE=""
PA_MARIADB_VERSAO_DE=""
PA_MAUTIC_VERSAO_PARA=""
PA_MARIADB_VERSAO_PARA=""
PA_MAUTIC_COMPOSE_MUDA=0
PA_MAUTIC_ATUALIZACAO_RETOMADA=0
PA_MAUTIC_TEMAS_EXTRAS=()
PA_MAUTIC_PLUGINS_EXTRAS=()

# 1 do fim do backup até o fim da atualização. É o que faz a saída
# com erro mostrar como restaurar.
PA_MAUTIC_TROCANDO=0

# 1 depois que o Mautic foi parado para o backup. Saindo com erro
# antes de qualquer troca, é o que faz a saída ligá-lo de novo.
PA_MAUTIC_PARADO=0

# ------------------------------------------------------------
# Leitura do estado
# ------------------------------------------------------------

# mautic_andamento_valor <chave>
#
# Ecoa um valor do arquivo de atualização em andamento, ou nada.
mautic_andamento_valor() {
	[[ -f "$PA_MAUTIC_ATUALIZANDO" ]] || return 0
	awk -F= -v chave="$1" '$1 == chave { sub(/^[^=]*=/, ""); print; exit }' \
		"$PA_MAUTIC_ATUALIZANDO"
}

# mautic_imagem_em_uso <servico>
#
# A imagem do container do serviço, parado ou não.
mautic_imagem_em_uso() {
	docker_imagem_do_servico "$PA_MAUTIC_DIR" "$1"
}

# mautic_versao_em_uso
#
# A versão do Mautic que está rodando, lida de dentro do container
# e não da tag da imagem: uma instalação antiga pode ter subido com
# a tag flutuante 7-apache, que não diz o número. Com o container
# parado, cai para a tag, quando ela é numerada.
mautic_versao_em_uso() {
	local versao=""
	versao="$(mautic_compose exec -T mautic_web \
		cat "${PA_MAUTIC_DOCROOT}/app/release_metadata.json" 2>/dev/null |
		sed -n 's/.*"version": *"\([0-9][0-9.]*\)".*/\1/p' | head -n 1)" || true

	if [[ -z "$versao" ]]; then
		local imagem
		imagem="$(mautic_imagem_em_uso mautic_web)"
		if [[ "$imagem" =~ ^mautic/mautic:([0-9]+\.[0-9]+\.[0-9]+)-apache$ ]]; then
			versao="${BASH_REMATCH[1]}"
		fi
	fi

	printf '%s\n' "$versao"
}

# mautic_banco_versao_em_uso
#
# A versão do MariaDB que está rodando, perguntada ao próprio banco.
# A senha vai por variável de ambiente (MYSQL_PWD), dentro do
# container, para não aparecer na lista de processos.
mautic_banco_versao_em_uso() {
	local versao=""
	# A expansão acontece dentro do container, não aqui.
	# shellcheck disable=SC2016
	versao="$(mautic_compose exec -T mariadb sh -c \
		'MYSQL_PWD="$MYSQL_PASSWORD" mariadb -N -umautic -e "select version()"' 2>/dev/null |
		sed -n 's/^\([0-9]*\.[0-9]*\.[0-9]*\).*/\1/p' | head -n 1)" || true

	if [[ -z "$versao" ]]; then
		local imagem
		imagem="$(mautic_imagem_em_uso mariadb)"
		if [[ "$imagem" =~ ^mariadb:([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
			versao="${BASH_REMATCH[1]}"
		fi
	fi

	printf '%s\n' "$versao"
}

# mautic_tamanho_banco_mb
#
# Tamanho do banco em MB, para a conta do espaço do backup.
mautic_tamanho_banco_mb() {
	local mb=""
	# shellcheck disable=SC2016
	mb="$(mautic_compose exec -T mariadb sh -c \
		'MYSQL_PWD="$MYSQL_PASSWORD" mariadb -N -umautic mautic -e "select coalesce(ceil(sum(data_length + index_length) / 1048576), 0) from information_schema.tables where table_schema = database()"' \
		2>/dev/null | tr -dc '0-9')" || true
	printf '%s\n' "${mb:-0}"
}

# mautic_listar_extras <themes|plugins>
#
# Pastas que não vieram na imagem: tema enviado pelo painel, plugin
# instalado pelo Marketplace. Moram na camada do container, fora de
# qualquer volume, e somem quando ele é recriado.
#
# Quem responde é o `docker diff`, que lista o que o container tem
# de diferente da imagem. Só o primeiro nível, e só nome simples.
mautic_listar_extras() {
	local id prefixo
	id="$(mautic_compose ps -aq mautic_web 2>/dev/null | head -n 1)" || true
	[[ -n "$id" ]] || return 0

	prefixo="A ${PA_MAUTIC_DOCROOT}/$1/"
	docker diff "$id" 2>/dev/null |
		awk -v p="$prefixo" '
			index($0, p) == 1 {
				resto = substr($0, length(p) + 1)
				if (resto ~ /^[A-Za-z0-9._-]+$/) print resto
			}' || true
}

# ------------------------------------------------------------
# Pré-condições
# ------------------------------------------------------------

# mautic_atualizar_exigir_concluida
#
# A atualização só roda sobre instalação concluída, a que tem a
# marca. Nos outros estados ela diz o que fazer antes.
mautic_atualizar_exigir_concluida() {
	local estado
	estado="$(mautic_detectar_estado)"

	case "$estado" in
		concluida) return 0 ;;
		perigoso) mautic_abortar_perigoso ;;
		nada)
			ui_fatal \
				"Não há Mautic instalado por este instalador nesta VPS." \
				"Não encontrei nada em ${PA_MAUTIC_DIR}." \
				"" \
				"Para instalar, rode sem --atualizar:" \
				"" \
				"    sudo bash ${0}"
			;;
		retomar)
			ui_fatal \
				"Há uma instalação que parou antes do fim." \
				"A atualização só roda sobre instalação concluída." \
				"" \
				"Rode sem --atualizar para concluir a instalação:" \
				"" \
				"    sudo bash ${0}" \
				"" \
				"Ela já termina na versão recomendada."
			;;
	esac
}

# mautic_atualizar_conferir_env
#
# O .env pode fixar a imagem (MAUTIC_IMAGE, MARIADB_IMAGE), e ele
# vence o padrão do compose. Como o instalador nunca mexe no .env,
# uma linha dessas apontando para outra versão faria a atualização
# regravar o compose e subir a mesma versão de antes.
mautic_atualizar_conferir_env() {
	local chave fixada recomendada

	for chave in MAUTIC_IMAGE MARIADB_IMAGE; do
		fixada="$(mautic_env_valor "$chave")"
		[[ -n "$fixada" ]] || continue

		recomendada="$PA_MAUTIC_IMAGEM_RECOMENDADA"
		[[ "$chave" == "MARIADB_IMAGE" ]] && recomendada="$PA_MARIADB_IMAGEM"
		[[ "$fixada" == "$recomendada" ]] && continue

		ui_fatal \
			"O .env desta instalação fixa a imagem, e ele vence o compose." \
			"" \
			"    ${chave}=${fixada}" \
			"    recomendada: ${recomendada}" \
			"" \
			"O instalador nunca altera o .env. Para atualizar, apague essa" \
			"linha de ${PA_MAUTIC_ENV}" \
			"e rode de novo. Nada foi alterado."
	done
}

# ------------------------------------------------------------
# Planejamento
# ------------------------------------------------------------

# mautic_atualizar_planejar
#
# Lê o que está instalado, decide o que muda e para quando não há
# nada a fazer ou quando atualizar seria voltar versão. Não altera
# nada além de gravar o compose novo num arquivo ao lado.
mautic_atualizar_planejar() {
	ui_secao "Conferindo a instalação"

	PA_DOMINIO="$(mautic_env_valor MAUTIC_DOMAIN)"
	if [[ -z "$PA_DOMINIO" ]]; then
		ui_fatal \
			"O .env desta instalação não diz o domínio." \
			"Falta a linha MAUTIC_DOMAIN= em ${PA_MAUTIC_ENV}."
	fi

	mautic_atualizar_conferir_env

	PA_MAUTIC_VERSAO_PARA="$(mautic_versao_da_imagem "$PA_MAUTIC_IMAGEM_RECOMENDADA")"
	PA_MARIADB_VERSAO_PARA="${PA_MARIADB_IMAGEM##*:}"

	# Atualização que parou no meio: o backup já existe e as versões
	# de antes estão anotadas. Ler de novo agora traria a versão de
	# um container que já pode ser o novo.
	if [[ -f "$PA_MAUTIC_ATUALIZANDO" ]]; then
		PA_MAUTIC_BACKUP="$(mautic_andamento_valor backup)"
		if [[ -n "$PA_MAUTIC_BACKUP" && -f "${PA_MAUTIC_BACKUP}/banco.sql.gz" ]]; then
			PA_MAUTIC_ATUALIZACAO_RETOMADA=1
			PA_MAUTIC_VERSAO_DE="$(mautic_andamento_valor mautic_de)"
			PA_MARIADB_VERSAO_DE="$(mautic_andamento_valor mariadb_de)"
		else
			ui_aviso "Havia uma atualização em andamento, mas o backup dela sumiu."
			ui_detalhe "Começo de novo, com um backup novo."
			rm -f "$PA_MAUTIC_ATUALIZANDO"
			PA_MAUTIC_BACKUP=""
		fi
	fi

	if [[ "$PA_MAUTIC_ATUALIZACAO_RETOMADA" -eq 0 ]]; then
		PA_MAUTIC_VERSAO_DE="$(mautic_versao_em_uso)"
		PA_MARIADB_VERSAO_DE="$(mautic_banco_versao_em_uso)"

		if [[ -z "$PA_MAUTIC_VERSAO_DE" || -z "$PA_MARIADB_VERSAO_DE" ]]; then
			ui_fatal \
				"Não consegui ler a versão que está em uso." \
				"O Mautic e o banco precisam estar no ar para a atualização" \
				"saber de onde está saindo. Suba a stack e rode de novo:" \
				"" \
				"    cd ${PA_MAUTIC_DIR} && docker compose up -d" \
				"" \
				"Nada foi alterado."
		fi

		PA_MAUTIC_BACKUP="${PA_MAUTIC_BACKUPS}/$(date +%Y-%m-%d-%H%M%S)"
	fi

	mautic_atualizar_recusar_volta "Mautic" \
		"$PA_MAUTIC_VERSAO_DE" "$PA_MAUTIC_VERSAO_PARA" '^7\.'
	mautic_atualizar_recusar_volta "MariaDB" \
		"$PA_MARIADB_VERSAO_DE" "$PA_MARIADB_VERSAO_PARA" '^10\.11\.'

	mautic_gerar_compose_novo
	PA_MAUTIC_COMPOSE_MUDA=1
	cmp -s "$PA_MAUTIC_COMPOSE_NOVO" "$PA_MAUTIC_COMPOSE" && PA_MAUTIC_COMPOSE_MUDA=0

	if [[ "$PA_MAUTIC_ATUALIZACAO_RETOMADA" -eq 1 ]]; then
		ui_ok "Atualização interrompida encontrada; sigo de onde ela parou"
		ui_detalhe "backup já feito: ${PA_MAUTIC_BACKUP}"
		mapfile -t PA_MAUTIC_TEMAS_EXTRAS < <(mautic_backup_listar temas)
		mapfile -t PA_MAUTIC_PLUGINS_EXTRAS < <(mautic_backup_listar plugins)
		return 0
	fi

	if [[ "$PA_MAUTIC_VERSAO_DE" == "$PA_MAUTIC_VERSAO_PARA" &&
		"$PA_MARIADB_VERSAO_DE" == "$PA_MARIADB_VERSAO_PARA" &&
		"$PA_MAUTIC_COMPOSE_MUDA" -eq 0 ]]; then
		rm -f "$PA_MAUTIC_COMPOSE_NOVO"
		ui_ok "Nada a atualizar"
		ui_detalhe "Mautic ${PA_MAUTIC_VERSAO_DE} e MariaDB ${PA_MARIADB_VERSAO_DE} já são as versões"
		ui_detalhe "recomendadas deste instalador, e o compose está em dia."
		ui_vazio
		ui_info "Nada foi alterado nesta máquina."
		ui_vazio
		exit 0
	fi

	mapfile -t PA_MAUTIC_TEMAS_EXTRAS < <(mautic_listar_extras themes)
	mapfile -t PA_MAUTIC_PLUGINS_EXTRAS < <(mautic_listar_extras plugins)

	ui_ok "Mautic ${PA_MAUTIC_VERSAO_DE} e MariaDB ${PA_MARIADB_VERSAO_DE} em uso"
}

# mautic_atualizar_recusar_volta <nome> <de> <para> <linha>
#
# Para em dois casos em que atualizar faria mal: a versão em uso é
# de outra linha principal, ou é mais nova que a recomendada deste
# instalador. No segundo, "atualizar" seria voltar versão, e o banco
# já migrado não volta.
mautic_atualizar_recusar_volta() {
	local nome="$1" de="$2" para="$3" linha="$4"

	if ! [[ "$de" =~ $linha ]]; then
		ui_fatal \
			"O ${nome} em uso é o ${de}, de outra linha." \
			"Este instalador só atualiza dentro da linha do ${nome} ${para}." \
			"Nada foi alterado."
	fi

	if docker_versao_maior "$de" "$para"; then
		ui_fatal \
			"O ${nome} em uso (${de}) é mais novo que o recomendado deste instalador (${para})." \
			"Atualizar seria voltar versão, e o banco já migrado não volta." \
			"" \
			"Baixe o instalador mais recente e rode a atualização com ele:" \
			"" \
			"    https://get.playahead.com.br/mautic7" \
			"" \
			"Nada foi alterado."
	fi
}

# mautic_gerar_compose_novo
#
# Grava, ao lado do compose instalado, o que este instalador
# gravaria hoje. Sempre com a imagem recomendada. O que a instalação
# decidiu sobre o certresolver é lido do compose antigo: se o label
# não está lá, o novo também sai sem ele.
mautic_gerar_compose_novo() {
	local label='traefik.http.routers.playahead-mautic.tls.certresolver='

	mautic_escrever_template "$PA_MAUTIC_COMPOSE_NOVO" "$PA_TEMPLATE_MAUTIC"

	if ! grep -q -- "^ *- \"${label}" "$PA_MAUTIC_COMPOSE"; then
		mautic_compose_sem_certresolver "$PA_MAUTIC_COMPOSE_NOVO"
	fi
}

# ------------------------------------------------------------
# Espaço em disco
# ------------------------------------------------------------

# mautic_atualizar_conferir_disco
#
# O backup do banco e a imagem nova precisam caber antes de qualquer
# coisa parar. Imagem antiga não é apagada pelo instalador.
mautic_atualizar_conferir_disco() {
	local banco precisa_backup precisa_imagem=0
	banco="$(mautic_tamanho_banco_mb)"
	# O dump comprimido fica bem menor que o banco, mas a conta usa o
	# tamanho cheio: sobrar é melhor que faltar no meio.
	precisa_backup=$((banco + 300))

	[[ "$PA_MARIADB_VERSAO_DE" != "$PA_MARIADB_VERSAO_PARA" ]] && precisa_imagem=600
	[[ "$PA_MAUTIC_VERSAO_DE" != "$PA_MAUTIC_VERSAO_PARA" ]] && precisa_imagem=3000

	local pasta_docker="/var/lib/docker"
	[[ -d "$pasta_docker" ]] || pasta_docker="/var"

	local disco_backup disco_docker livre_backup livre_docker
	read -r disco_backup livre_backup < <(df -Pm "$PA_MAUTIC_DIR" | awk 'NR==2 {print $1, $4}')
	read -r disco_docker livre_docker < <(df -Pm "$pasta_docker" | awk 'NR==2 {print $1, $4}')

	# No mesmo disco, que é o caso de quase toda VPS, as duas contas
	# disputam o mesmo espaço.
	if [[ "$disco_backup" == "$disco_docker" ]]; then
		precisa_backup=$((precisa_backup + precisa_imagem))
		precisa_imagem=0
	fi

	if [[ "$livre_backup" -lt "$precisa_backup" || "$livre_docker" -lt "$precisa_imagem" ]]; then
		ui_fatal \
			"Falta espaço em disco para atualizar com segurança." \
			"" \
			"    banco de dados:   ${banco} MB" \
			"    livre no disco:   ${livre_backup} MB" \
			"    necessário:       $((precisa_backup + precisa_imagem)) MB (backup e imagem nova)" \
			"" \
			"Libere espaço e rode de novo. Nada foi alterado."
	fi

	ui_ok "Espaço em disco: ${livre_backup} MB livres, ${precisa_backup} MB necessários"
}

# ------------------------------------------------------------
# Confirmação
# ------------------------------------------------------------

# mautic_atualizar_descrever <de> <para>
mautic_atualizar_descrever() {
	if [[ "$1" == "$2" ]]; then
		printf '%s (sem mudança)\n' "$1"
	else
		printf '%s para %s\n' "$1" "$2"
	fi
}

# mautic_atualizar_confirmar
#
# Último ponto antes de parar o site. O resumo sai sempre, inclusive
# com --yes. A pergunta tem "não" como resposta do Enter: aqui o
# engano custa o site fora do ar.
mautic_atualizar_confirmar() {
	local acao_compose="sem mudança"
	[[ "$PA_MAUTIC_COMPOSE_MUDA" -eq 1 ]] &&
		acao_compose="regravar a partir deste instalador"

	local situacao="atualização"
	[[ "$PA_MAUTIC_ATUALIZACAO_RETOMADA" -eq 1 ]] &&
		situacao="continuando a atualização interrompida"

	ui_resumo "Confira antes de atualizar" \
		"Situação" "$situacao" detectado \
		"Domínio" "https://${PA_DOMINIO}" detectado \
		"Mautic" "$(mautic_atualizar_descrever "$PA_MAUTIC_VERSAO_DE" "$PA_MAUTIC_VERSAO_PARA")" detectado \
		"MariaDB" "$(mautic_atualizar_descrever "$PA_MARIADB_VERSAO_DE" "$PA_MARIADB_VERSAO_PARA")" detectado \
		"Compose" "$acao_compose" detectado \
		"Backup" "$PA_MAUTIC_BACKUP" padrao

	ui_info "O site fica fora do ar durante a troca. Costuma levar"
	ui_info "alguns minutos; com banco grande, mais."
	ui_info "A migração do banco não tem volta automática: o caminho de"
	ui_info "volta é o backup, feito antes de qualquer troca."

	mautic_atualizar_avisar_compose
	mautic_atualizar_avisar_extras
	ui_vazio

	ui_interativo || return 0

	if ui_confirmar "Posso atualizar?" 0; then
		return 0
	fi

	rm -f "$PA_MAUTIC_COMPOSE_NOVO"
	ui_vazio
	ui_info "Nada foi alterado nesta máquina."
	ui_vazio
	exit 0
}

# mautic_atualizar_avisar_compose
#
# Acréscimo do Fabio ao desenho: se a pessoa mexeu no compose, ela
# precisa saber antes que a alteração não vai junto.
mautic_atualizar_avisar_compose() {
	[[ "$PA_MAUTIC_COMPOSE_MUDA" -eq 1 ]] || return 0
	[[ "$PA_MAUTIC_ATUALIZACAO_RETOMADA" -eq 0 ]] || return 0

	case "$(mautic_compose_situacao)" in
		intacto) return 0 ;;
		alterado)
			ui_vazio
			ui_aviso "O docker-compose.yml foi alterado depois da instalação."
			ui_detalhe "A alteração NÃO vai junto: o arquivo é regravado a partir"
			ui_detalhe "deste instalador. O antigo fica guardado no backup:"
			ui_detalhe "${PA_MAUTIC_BACKUP}/docker-compose.yml"
			ui_detalhe "Se ela ainda for necessária, refaça no arquivo novo depois."
			;;
		*)
			ui_vazio
			ui_aviso "Não sei dizer se o docker-compose.yml foi alterado à mão."
			ui_detalhe "Esta instalação é anterior ao registro que permite conferir."
			ui_detalhe "Se você mexeu nele, a alteração NÃO vai junto: o arquivo é"
			ui_detalhe "regravado. O antigo fica guardado no backup:"
			ui_detalhe "${PA_MAUTIC_BACKUP}/docker-compose.yml"
			;;
	esac
}

# mautic_atualizar_avisar_extras
#
# Temas e plugins instalados pelo painel moram dentro do container,
# e trocar a imagem recria o container. Os temas voltam sozinhos,
# porque são só arquivos. Plugin não: o Marketplace instala pelo
# composer, com dependências em vendor/, e copiar a pasta de volta
# deixaria um plugin pela metade.
mautic_atualizar_avisar_extras() {
	if [[ "${#PA_MAUTIC_TEMAS_EXTRAS[@]}" -gt 0 ]]; then
		ui_vazio
		ui_info "Temas instalados pelo painel: ${PA_MAUTIC_TEMAS_EXTRAS[*]}"
		ui_detalhe "Vão para o backup e são devolvidos depois da troca."
	fi

	if [[ "${#PA_MAUTIC_PLUGINS_EXTRAS[@]}" -gt 0 ]]; then
		ui_vazio
		ui_aviso "Plugins instalados pelo painel: ${PA_MAUTIC_PLUGINS_EXTRAS[*]}"
		ui_detalhe "Eles NÃO voltam sozinhos: moram dentro do container, que é"
		ui_detalhe "recriado. Uma cópia vai para o backup, e depois da troca"
		ui_detalhe "você reinstala pelo Marketplace do Mautic."
	fi

	return 0
}

# ------------------------------------------------------------
# Backup
# ------------------------------------------------------------

# mautic_backup_listar <temas|plugins>
#
# Os nomes guardados num backup já feito, para a retomada.
mautic_backup_listar() {
	local pasta="${PA_MAUTIC_BACKUP}/$1"
	[[ -d "$pasta" ]] || return 0
	find "$pasta" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null || true
}

# mautic_backup_banco <arquivo.sql.gz>
#
# Dump do banco inteiro, com o DROP e o CREATE do banco dentro, para
# que restaurar seja um comando só e não deixe para trás tabela que
# a versão nova criou.
#
# --single-transaction lê uma fotografia consistente sem travar
# tabela. O Mautic já está parado nesta hora, então a fotografia é o
# estado final. A senha vai por MYSQL_PWD, dentro do container, para
# não aparecer na lista de processos.
#
# Conferido no fim: o mariadb-dump só escreve "Dump completed" na
# última linha quando chegou ao fim.
mautic_backup_banco() {
	local arquivo="$1"

	# shellcheck disable=SC2016
	if ! mautic_compose exec -T mariadb sh -c \
		'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mariadb-dump -uroot --single-transaction --quick --routines --triggers --add-drop-database --databases mautic' \
		2>"${arquivo}.erro" | gzip >"$arquivo"; then
		return 1
	fi

	gzip -t "$arquivo" 2>/dev/null || return 1
	gunzip -c "$arquivo" | tail -n 1 | grep -q 'Dump completed' || return 1

	rm -f "${arquivo}.erro"
}

# mautic_backup_extras <themes|plugins> <temas|plugins> <nomes...>
mautic_backup_extras() {
	local origem="$1" destino="${PA_MAUTIC_BACKUP}/$2"
	shift 2
	[[ "$#" -gt 0 ]] || return 0

	local id nome
	id="$(mautic_compose ps -aq mautic_web 2>/dev/null | head -n 1)" || true
	[[ -n "$id" ]] || return 1

	mkdir -p "$destino"
	for nome in "$@"; do
		docker cp "${id}:${PA_MAUTIC_DOCROOT}/${origem}/${nome}" "${destino}/" >/dev/null 2>&1 ||
			return 1
	done
}

# mautic_fazer_backup
#
# Tudo que a atualização pode estragar, numa pasta só, legível só
# por root: o dump tem os contatos, e o .env tem as senhas.
mautic_fazer_backup() {
	ui_passo "Fazendo o backup"

	local mascara_antiga
	mascara_antiga="$(umask)"
	umask 077

	mkdir -p "$PA_MAUTIC_BACKUP"
	chmod 700 "$PA_MAUTIC_BACKUPS" "$PA_MAUTIC_BACKUP"

	if ! mautic_backup_banco "${PA_MAUTIC_BACKUP}/banco.sql.gz"; then
		umask "$mascara_antiga"
		ui_fatal \
			"O backup do banco não terminou. A atualização parou aqui." \
			"" \
			"O que o banco respondeu está em:" \
			"    ${PA_MAUTIC_BACKUP}/banco.sql.gz.erro"
	fi
	ui_ok "Banco de dados: $(du -h "${PA_MAUTIC_BACKUP}/banco.sql.gz" | awk '{print $1}') (comprimido, conferido até o fim)"

	cp -p "$PA_MAUTIC_COMPOSE" "${PA_MAUTIC_BACKUP}/docker-compose.yml"
	cp -p "$PA_MAUTIC_ENV" "${PA_MAUTIC_BACKUP}/.env"
	[[ -f "$PA_MAUTIC_CREDENCIAIS" ]] &&
		cp -p "$PA_MAUTIC_CREDENCIAIS" "${PA_MAUTIC_BACKUP}/credenciais.txt"

	local config
	config="$(docker volume inspect -f '{{.Mountpoint}}' "$PA_MAUTIC_VOLUME_CONFIG" 2>/dev/null)" || true
	if [[ -n "$config" && -f "${config}/local.php" ]]; then
		mkdir -p "${PA_MAUTIC_BACKUP}/config"
		cp -p "${config}/local.php" "${PA_MAUTIC_BACKUP}/config/"
		[[ -f "${config}/parameters_local.php" ]] &&
			cp -p "${config}/parameters_local.php" "${PA_MAUTIC_BACKUP}/config/"
	fi
	ui_ok "Compose, .env e configuração do Mautic"

	if ! mautic_backup_extras themes temas "${PA_MAUTIC_TEMAS_EXTRAS[@]}" ||
		! mautic_backup_extras plugins plugins "${PA_MAUTIC_PLUGINS_EXTRAS[@]}"; then
		umask "$mascara_antiga"
		ui_fatal \
			"Não consegui copiar os temas e plugins para o backup." \
			"A atualização parou aqui."
	fi
	if [[ "${#PA_MAUTIC_TEMAS_EXTRAS[@]}" -gt 0 || "${#PA_MAUTIC_PLUGINS_EXTRAS[@]}" -gt 0 ]]; then
		ui_ok "Temas e plugins instalados pelo painel"
	fi

	mautic_atualizar_como_restaurar arquivo >"${PA_MAUTIC_BACKUP}/COMO-RESTAURAR.txt"

	# Fecha o que foi criado, sem depender do umask. Medido na máquina
	# do GitHub em 2026-11-11: com o umask em 077, o dump nasceu com
	# modo 666 dentro da pasta 700, o que é o sinal de pasta com ACL
	# padrão, onde o umask não vale. A pasta fechada já impedia o
	# acesso; o chmod explícito tira a dependência. Só o primeiro
	# nível e a configuração: os arquivos dos temas voltam para o
	# container com o modo que tinham.
	find "$PA_MAUTIC_BACKUP" -maxdepth 1 -exec chmod go-rwx {} +
	if [[ -d "${PA_MAUTIC_BACKUP}/config" ]]; then
		chmod -R go-rwx "${PA_MAUTIC_BACKUP}/config"
	fi

	# Só agora: este arquivo é a promessa de que o backup terminou.
	{
		printf 'backup=%s\n' "$PA_MAUTIC_BACKUP"
		printf 'mautic_de=%s\n' "$PA_MAUTIC_VERSAO_DE"
		printf 'mariadb_de=%s\n' "$PA_MARIADB_VERSAO_DE"
	} >"$PA_MAUTIC_ATUALIZANDO"

	umask "$mascara_antiga"

	ui_ok "Backup completo em ${PA_MAUTIC_BACKUP}"
}

# mautic_atualizar_religar
#
# Saída com erro antes de qualquer troca: liga de novo o que foi
# parado para o backup, na versão de antes.
#
# Primeiro espera a parada terminar, e só então liga. Medido em
# 2026-11-11: um Ctrl-C no meio do "docker compose stop" interrompe
# o comando, mas não a parada, que continua valendo dentro do
# Docker. Ligar na hora não tinha efeito, e os containers caíam dez
# segundos depois, com a tela dizendo que tinham sido ligados.
#
# Os dois comandos rodam em sessão própria, para um segundo Ctrl-C
# não deixar o serviço pela metade.
mautic_atualizar_religar() {
	mautic_compose_desligado stop mautic_cron mautic_worker mautic_web || true
	mautic_compose_desligado start mautic_web mautic_cron mautic_worker || true
}

# ------------------------------------------------------------
# Como restaurar
# ------------------------------------------------------------

# mautic_atualizar_como_restaurar
#
# O mesmo texto vai para a tela, quando a atualização sai com erro,
# e para o arquivo COMO-RESTAURAR.txt dentro do backup.
mautic_atualizar_como_restaurar() {
	local pasta="$PA_MAUTIC_BACKUP"

	# Na tela, o texto vem depois de uma atualização que saiu com
	# erro. No arquivo do backup ele é lido meses depois, por quem
	# não está no meio de atualização nenhuma.
	printf '\n'
	if [[ "${1:-}" == "arquivo" ]]; then
		printf '  Backup feito em %s, antes de atualizar o Mautic\n' "$(date +%Y-%m-%d)"
		printf '  %s para o %s.\n' "$PA_MAUTIC_VERSAO_DE" "$PA_MAUTIC_VERSAO_PARA"
		printf '\n'
		printf '  Pasta deste backup:\n'
		printf '      %s\n' "$pasta"
	else
		printf '  A atualização do Mautic não terminou.\n'
		printf '\n'
		printf '  O backup de antes dela está inteiro em:\n'
		printf '      %s\n' "$pasta"
		printf '\n'
		printf '  PARA CONTINUAR de onde parou (o backup não é refeito):\n'
		printf '\n'
		printf '      sudo bash %s --atualizar\n' "$0"
	fi
	printf '\n'
	printf '  PARA VOLTAR ao Mautic %s, como estava antes:\n' "$PA_MAUTIC_VERSAO_DE"
	printf '\n'
	printf '      cd %s\n' "$PA_MAUTIC_DIR"
	printf '      docker compose stop mautic_web mautic_cron mautic_worker\n'
	printf '      cp %s/docker-compose.yml docker-compose.yml\n' "$pasta"
	printf '      docker compose up -d mariadb\n'
	printf '      gunzip -c %s/banco.sql.gz | docker compose exec -T mariadb \\\n' "$pasta"
	# As aspas simples são do comando que a pessoa vai colar.
	# shellcheck disable=SC2016
	printf '        sh -c %s\n' "'MYSQL_PWD=\"\$MYSQL_ROOT_PASSWORD\" mariadb -uroot'"
	printf '      docker compose up -d\n'
	printf '      rm -f %s %s\n' "$PA_MAUTIC_ATUALIZANDO" "${PA_MAUTIC_DIR}/.compose.sha256"
	printf '\n'
	printf '  O comando do gunzip apaga o banco atual e devolve o do backup.\n'
	printf '  Espere o banco ficar no ar (docker compose ps) antes de rodá-lo.\n'
	if [[ "${#PA_MAUTIC_TEMAS_EXTRAS[@]}" -gt 0 || "${#PA_MAUTIC_PLUGINS_EXTRAS[@]}" -gt 0 ]]; then
		printf '  Temas e plugins instalados pelo painel estão em %s,\n' "$pasta"
		printf '  nas pastas temas e plugins.\n'
	fi
	printf '\n'
}

# mautic_atualizar_ao_sair
#
# Tratador de saída da atualização, para erro e para Ctrl-C. São
# dois casos:
#
#   - depois do backup, mostra como continuar e como voltar;
#   - entre parar o Mautic e terminar o backup, nada foi trocado:
#     liga o Mautic de novo, para o site não ficar fora do ar por
#     causa de uma atualização que nem começou.
#
# Escreve na cópia da tela guardada pelo ui_tratar_interrupcao, pelo
# mesmo motivo do Ctrl-C: a saída do momento pode estar
# redirecionada.
mautic_atualizar_ao_sair() {
	local codigo=$?

	if [[ "$codigo" -ne 0 && "$PA_MAUTIC_TROCANDO" -eq 1 ]]; then
		mautic_atualizar_como_restaurar >&"$PA_UI_FD_TELA" 2>&1 || true
	elif [[ "$codigo" -ne 0 && "$PA_MAUTIC_PARADO" -eq 1 ]]; then
		printf '  Nada foi trocado. Ligando o Mautic de novo, na versão de antes.\n' \
			>&"$PA_UI_FD_TELA" 2>&1 || true
		mautic_atualizar_religar
		{
			printf '  Mautic ligado. Para tentar outra vez:\n'
			printf '      sudo bash %s --atualizar\n\n' "$0"
		} >&"$PA_UI_FD_TELA" 2>&1 || true
	fi

	ui_restaurar_terminal
}

# ------------------------------------------------------------
# A troca
# ------------------------------------------------------------

# mautic_compose_desligado <argumentos...>
#
# O `docker compose` da stack numa sessão própria, para a troca de
# container terminar mesmo que o terminal caia no meio. O motivo
# está em docker_compose_desligado.
mautic_compose_desligado() {
	docker_compose_desligado "$PA_MAUTIC_DIR" "$@"
}

# mautic_atualizar_baixar
#
# Antes de parar qualquer coisa. Falhando aqui, nada mudou.
mautic_atualizar_baixar() {
	ui_passo "Baixando as imagens novas"
	if [[ "$PA_MAUTIC_ATUALIZACAO_RETOMADA" -eq 0 ]]; then
		ui_detalhe "O site continua no ar enquanto isso. O progresso aparece abaixo."
	fi

	local imagem
	for imagem in "$PA_MARIADB_IMAGEM" "$PA_MAUTIC_IMAGEM_RECOMENDADA"; do
		if docker image inspect "$imagem" >/dev/null 2>&1; then
			ui_ok "${imagem} já está nesta máquina"
			continue
		fi
		if ! docker pull "$imagem"; then
			rm -f "$PA_MAUTIC_COMPOSE_NOVO"
			ui_fatal \
				"Não consegui baixar ${imagem}." \
				"Nada foi alterado, e o Mautic segue no ar na versão de antes." \
				"Confira a conexão da VPS com o Docker Hub e rode de novo."
		fi
		ui_ok "${imagem} baixada"
	done
}

# mautic_atualizar_parar
mautic_atualizar_parar() {
	ui_passo "Parando o Mautic"
	ui_detalhe "O site fica fora do ar a partir daqui, até a versão nova subir."

	PA_MAUTIC_PARADO=1
	mautic_compose stop mautic_cron mautic_worker mautic_web >/dev/null 2>&1 ||
		ui_fatal \
			"Não consegui parar os containers do Mautic." \
			"Nada foi trocado. Veja o estado com:" \
			"" \
			"    cd ${PA_MAUTIC_DIR} && docker compose ps"

	ui_ok "Mautic, agendador e workers parados; o banco segue no ar"
}

# mautic_atualizar_trocar_compose
mautic_atualizar_trocar_compose() {
	if [[ "$PA_MAUTIC_COMPOSE_MUDA" -eq 1 ]]; then
		mv -f "$PA_MAUTIC_COMPOSE_NOVO" "$PA_MAUTIC_COMPOSE"
		ui_ok "docker-compose.yml regravado a partir deste instalador"
	else
		rm -f "$PA_MAUTIC_COMPOSE_NOVO"
		ui_ok "docker-compose.yml já está em dia"
	fi

	mautic_compose_registrar_hash
}

# mautic_atualizar_subir
#
# Banco, depois a web, depois o resto, como na instalação. A imagem
# do Mautic aplica as migrações do banco na subida da web, e é por
# isso que a espera dela é longa.
mautic_atualizar_subir() {
	ui_passo "Subindo o banco de dados"
	mautic_compose_desligado up -d mariadb ||
		ui_fatal \
			"Falha ao subir o MariaDB ${PA_MARIADB_VERSAO_PARA}." \
			"Veja o log:" \
			"" \
			"    cd ${PA_MAUTIC_DIR} && docker compose logs mariadb"

	ui_aguardar_ate "Aguardando o banco aceitar conexão" 300 \
		mautic_container_saudavel mariadb ||
		ui_fatal \
			"O banco subiu mas não ficou saudável." \
			"Veja o log:" \
			"" \
			"    cd ${PA_MAUTIC_DIR} && docker compose logs mariadb"

	ui_passo "Subindo o Mautic ${PA_MAUTIC_VERSAO_PARA}"
	ui_detalhe "A versão nova aplica as migrações do banco ao subir."
	mautic_compose_desligado up -d mautic_web ||
		ui_fatal \
			"Falha ao subir o Mautic ${PA_MAUTIC_VERSAO_PARA}." \
			"Veja o log:" \
			"" \
			"    cd ${PA_MAUTIC_DIR} && docker compose logs mautic_web"

	ui_aguardar_ate "Aguardando o Mautic responder" 900 \
		mautic_container_saudavel mautic_web ||
		ui_fatal \
			"O Mautic novo subiu mas não respondeu no tempo esperado." \
			"Com banco grande, a migração pode ainda estar rodando. Veja:" \
			"" \
			"    cd ${PA_MAUTIC_DIR} && docker compose logs --tail 50 mautic_web"

	local subiu
	subiu="$(mautic_versao_em_uso)"
	if [[ "$subiu" == "$PA_MAUTIC_VERSAO_PARA" ]]; then
		ui_ok "Mautic ${subiu} no ar"
	else
		ui_aviso "O Mautic subiu, mas diz ser a versão ${subiu:-desconhecida}, e não a ${PA_MAUTIC_VERSAO_PARA}."
		ui_detalhe "Confira se o .env fixa outra imagem (MAUTIC_IMAGE)."
	fi

	if mautic_console doctrine:migrations:up-to-date; then
		ui_ok "Migrações do banco em dia"
	else
		ui_aviso "O Mautic diz que há migração de banco pendente."
		ui_detalhe "Veja o que ficou faltando:"
		ui_detalhe "cd ${PA_MAUTIC_DIR} && docker compose exec -u www-data -w ${PA_MAUTIC_WORKDIR} \\"
		ui_detalhe "  mautic_web php bin/console doctrine:migrations:status"
	fi

	mautic_atualizar_devolver_temas

	ui_passo "Subindo o agendador e os workers"
	mautic_compose_desligado up -d ||
		ui_fatal \
			"Falha ao subir cron e worker." \
			"O Mautic já está no ar; isto afeta campanhas e envios." \
			"Veja o log:" \
			"" \
			"    cd ${PA_MAUTIC_DIR} && docker compose logs mautic_cron"
	ui_ok "Agendador e workers no ar"

	mautic_conferir_workers
}

# mautic_atualizar_devolver_temas
#
# Copia os temas do backup para o container novo e devolve o dono
# para o www-data: o docker cp grava como root, e o Mautic não
# conseguiria editar o tema pelo painel. Avisa em vez de parar: o
# Mautic já está no ar, e a cópia continua no backup.
mautic_atualizar_devolver_temas() {
	[[ "${#PA_MAUTIC_TEMAS_EXTRAS[@]}" -gt 0 ]] || return 0

	local id nome ruim=0
	id="$(mautic_compose ps -q mautic_web 2>/dev/null | head -n 1)" || true

	for nome in "${PA_MAUTIC_TEMAS_EXTRAS[@]}"; do
		if [[ -n "$id" && -d "${PA_MAUTIC_BACKUP}/temas/${nome}" ]] &&
			docker cp "${PA_MAUTIC_BACKUP}/temas/${nome}" \
				"${id}:${PA_MAUTIC_DOCROOT}/themes/" >/dev/null 2>&1 &&
			mautic_compose exec -T mautic_web chown -R www-data:www-data \
				"${PA_MAUTIC_DOCROOT}/themes/${nome}" >/dev/null 2>&1; then
			continue
		fi
		ruim=1
	done

	if [[ "$ruim" -eq 0 ]]; then
		ui_ok "Temas devolvidos: ${PA_MAUTIC_TEMAS_EXTRAS[*]}"
	else
		ui_aviso "Não consegui devolver todos os temas instalados pelo painel."
		ui_detalhe "A cópia está em ${PA_MAUTIC_BACKUP}/temas."
	fi
}

# ------------------------------------------------------------
# Registro e bloco final
# ------------------------------------------------------------

# mautic_atualizar_registrar
#
# Regrava o credenciais.txt com a versão nova, mantendo o e-mail e a
# senha do admin que já estavam lá (o antigo também vai no backup),
# e acrescenta uma linha na marca de instalação concluída.
mautic_atualizar_registrar() {
	mautic_ler_credenciais
	[[ -n "$PA_EMAIL_ADMIN" ]] || PA_EMAIL_ADMIN="$(mautic_email_admin_do_banco)"
	PA_MAUTIC_SENHA_BANCO="$(mautic_env_valor MYSQL_PASSWORD)"
	PA_MAUTIC_JA_INSTALADO=1

	PA_MAUTIC_NOTA_ATUALIZACAO="atualizado em $(date +%Y-%m-%d): Mautic $(mautic_atualizar_descrever "$PA_MAUTIC_VERSAO_DE" "$PA_MAUTIC_VERSAO_PARA"), MariaDB $(mautic_atualizar_descrever "$PA_MARIADB_VERSAO_DE" "$PA_MARIADB_VERSAO_PARA")"

	mautic_testar_smtp
	mautic_gravar_credenciais "$PA_DOMINIO" "$PA_EMAIL_ADMIN"

	printf 'Atualizada em %s pelo %s %s: Mautic %s, MariaDB %s. Backup em %s.\n' \
		"$(date -Is)" "$PA_FERRAMENTA" "$PA_VERSAO" \
		"$(mautic_atualizar_descrever "$PA_MAUTIC_VERSAO_DE" "$PA_MAUTIC_VERSAO_PARA")" \
		"$(mautic_atualizar_descrever "$PA_MARIADB_VERSAO_DE" "$PA_MARIADB_VERSAO_PARA")" \
		"$PA_MAUTIC_BACKUP" >>"$PA_MAUTIC_MARCA"
}

mautic_atualizar_bloco_final() {
	ui_vazio
	ui_secao "Atualização concluída"

	ui_info "URL:      https://${PA_DOMINIO}"
	ui_info "Mautic:   $(mautic_atualizar_descrever "$PA_MAUTIC_VERSAO_DE" "$PA_MAUTIC_VERSAO_PARA")"
	ui_info "MariaDB:  $(mautic_atualizar_descrever "$PA_MARIADB_VERSAO_DE" "$PA_MARIADB_VERSAO_PARA")"
	ui_vazio
	ui_info "O e-mail e a senha de acesso continuam os mesmos."
	ui_vazio
	ui_info "Backup de antes da atualização:"
	ui_detalhe "$PA_MAUTIC_BACKUP"
	ui_detalhe "Como voltar, se precisar: COMO-RESTAURAR.txt, dentro dele."
	ui_detalhe "O instalador não apaga backup. Quando tiver certeza de que"
	ui_detalhe "está tudo certo, apague a pasta para liberar espaço."

	if [[ "${#PA_MAUTIC_PLUGINS_EXTRAS[@]}" -gt 0 ]]; then
		ui_vazio
		ui_aviso "Reinstale pelo Marketplace do Mautic: ${PA_MAUTIC_PLUGINS_EXTRAS[*]}"
		ui_detalhe "Plugin instalado pelo painel não sobrevive à troca de versão."
		ui_detalhe "A cópia de antes está em ${PA_MAUTIC_BACKUP}/plugins."
	fi

	if [[ "$PA_MAUTIC_VERSAO_DE" != "$PA_MAUTIC_VERSAO_PARA" ]]; then
		ui_vazio
		ui_info "A imagem da versão antiga continua no disco. Para ver:"
		ui_detalhe "docker image ls mautic/mautic"
	fi

	ui_vazio
	ui_info "Abra no navegador para conferir: https://${PA_DOMINIO}"
	ui_vazio
}

# ------------------------------------------------------------
# Orquestração
# ------------------------------------------------------------

# mautic_atualizar
#
# Chamado pelo main quando há --atualizar, depois de conferir que a
# base está pronta.
mautic_atualizar() {
	mautic_atualizar_exigir_concluida
	mautic_atualizar_planejar

	if [[ "$PA_MAUTIC_ATUALIZACAO_RETOMADA" -eq 0 ]]; then
		mautic_atualizar_conferir_disco
	fi

	mautic_atualizar_confirmar

	ui_secao "Atualizando o Mautic"

	# A dica do Ctrl-C da instalação fala em domínio e em retomar a
	# instalação. Aqui o que vale é a da atualização.
	PA_UI_DICA_INTERRUPCAO=("Para continuar a atualização, rode o mesmo comando de novo.")
	trap mautic_atualizar_ao_sair EXIT

	mautic_atualizar_baixar

	ui_marcar_alteracao

	if [[ "$PA_MAUTIC_ATUALIZACAO_RETOMADA" -eq 0 ]]; then
		mautic_atualizar_parar
		mautic_fazer_backup
	fi

	# Daqui em diante, sair com erro mostra como continuar e como
	# voltar, em vez de ligar a versão de antes.
	PA_MAUTIC_TROCANDO=1

	mautic_atualizar_trocar_compose
	mautic_atualizar_subir

	mautic_verificar_roteamento "$PA_DOMINIO" || true

	mautic_atualizar_registrar

	rm -f "$PA_MAUTIC_ATUALIZANDO"
	PA_MAUTIC_TROCANDO=0

	mautic_atualizar_bloco_final
}
