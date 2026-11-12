#!/usr/bin/env bash
# shellcheck shell=bash
#
# ============================================================
# build.sh
# Gera os artefatos de dist/ a partir de lib/*.sh.
#
# O código-fonte é modular, mas o que é publicado são arquivos
# únicos: um script baixado sozinho por curl não consegue dar
# source em arquivos que não existem na VPS.
#
# Tres alvos hoje:
#     dist/base.sh        Docker, Traefik e Portainer
#     dist/mautic7.sh     Mautic 7
#     dist/playahead.sh   menu, com os instaladores embutidos
#
# A ORDEM IMPORTA: o menu embute os outros dois, entao eles precisam
# estar gerados antes.
#
# USO
#     ./build.sh            gera os tres
#     ./build.sh --check    só verifica se dist/ está em dia
#                           (para CI e para o hook de commit)
# ============================================================

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

# ------------------------------------------------------------
# Configuração
# ------------------------------------------------------------

# Dois alvos, declarados lado a lado. NÃO é um sistema genérico de
# alvos: quando o terceiro instalador existir, ele se acrescenta
# copiando cinco linhas. Diretório targets/, manifesto e laço sobre
# uma lista de alvos externa ficam de fora até que haja motivo.
#
# A ORDEM DAS LIBS IMPORTA. Não é alfabética, é a ordem de
# dependência: ui primeiro porque todo mundo usa ui_fatal, e o
# orquestrador por último porque é quem chama todos os outros.
#
# Cada artefato leva só o que usa. O instalador de ferramenta
# detecta Docker e Traefik mas não os instala, então os módulos de
# instalação, a descoberta de portas e o swap não entram nele.

# A ordem desta lista e de dependencia, nao de gosto: o menu embute
# os artefatos dos outros dois, e por isso vem por ultimo.
PA_ALVOS=(base mautic7 playahead)

# Saída e template por alvo em array associativo, e não em nome de
# variável montado em tempo de execução: assim o shellcheck
# consegue rastrear o uso. Só as listas de libs ficam como arrays
# separados, porque array dentro de array não existe em bash.
declare -A PA_SAIDA=(
	[base]="dist/base.sh"
	[mautic7]="dist/mautic7.sh"
	[playahead]="dist/playahead.sh"
)

# A base não tem template: os composes do Traefik e do Portainer
# são gerados em código, porque dependem de valores descobertos em
# execução.
declare -A PA_TEMPLATE=(
	[base]=""
	[mautic7]="templates/docker-compose-mautic7-playahead.yml"
	[playahead]=""
)

# Artefatos que o menu carrega dentro de si. Só ele embute outros
# artefatos, então isto é um caso próprio e não um sistema: o dia em
# que houver um segundo menu, aí se generaliza.
#
# A ordem aqui é a ordem da lista do menu.
PA_EMBUTIDOS=(base mautic7)

# Como cada instalador embutido aparece no menu. O menu não tem lista
# própria: o build escreve, para cada embutido, uma chamada a
# menu_registrar com estes textos e com a versão lida do orquestrador.
# Instalador novo que entra em PA_EMBUTIDOS ganha quatro linhas aqui e
# aparece na lista, sem tocar no lib/menu_main.sh.
#
#   nome        como aparece na lista
#   descrição   uma frase curta, ao lado do nome
#   grupo       infraestrutura, marketing ou atendimento. Ainda não
#               aparece na tela; ver "O menu", no CLAUDE.md
#   instalado   arquivo que só existe na VPS depois de o instalador
#               ter terminado. Mais de um, separados por espaço: basta
#               um deles existir
declare -A PA_MENU_NOME=(
	[base]="Base"
	[mautic7]="Mautic 7"
)

declare -A PA_MENU_DESCRICAO=(
	[base]="Docker, Traefik e Portainer. Uma vez por VPS."
	[mautic7]="Precisa da base instalada."
)

declare -A PA_MENU_GRUPO=(
	[base]="infraestrutura"
	[mautic7]="marketing"
)

declare -A PA_MENU_INSTALADO=(
	[base]="/opt/playahead/traefik/docker-compose.yml /opt/playahead/portainer/docker-compose.yml"
	[mautic7]="/opt/playahead/mautic/.instalacao-concluida"
)

# Lidas por nameref em gerar(); o shellcheck não enxerga uso por
# nameref, daí a diretiva.
# shellcheck disable=SC2034
PA_LIBS_base=(
	ui
	checks
	portas
	sistema
	docker
	docker_instalar
	traefik
	traefik_instalar
	cenario
	portainer
	base_atualizar
	base_main
)

# shellcheck disable=SC2034
PA_LIBS_mautic7=(
	ui
	checks
	docker
	traefik
	cenario
	mautic
	mautic_atualizar
	mautic_main
)

# O menu não precisa de detecção nem de checagem: ele grava um
# instalador e passa o terminal para ele. Quem detecta e decide é o
# instalador escolhido.
# shellcheck disable=SC2034
PA_LIBS_playahead=(
	ui
	menu_main
)

PA_FONTE="https://github.com/play-ahead/playahead-installer"

# Delimitadores dos heredocs que embutem conteúdo. Precisam ser algo
# que não apareça dentro do que está sendo embutido; o build confere.
#
# O do instalador é diferente do do template de propósito: o
# mautic7.sh já carrega o template dentro dele, e o menu carrega o
# mautic7.sh inteiro. São dois heredocs aninhados, e o de fora só
# termina no delimitador dele.
PA_DELIM="PA_FIM_DO_TEMPLATE_MAUTIC"
PA_DELIM_INSTALADOR="PA_FIM_DO_INSTALADOR"

# ------------------------------------------------------------
# Mensagens
# ------------------------------------------------------------

erro() {
	printf 'build: %s\n' "$*" >&2
	exit 1
}

info() {
	printf 'build: %s\n' "$*"
}

# ------------------------------------------------------------
# Leitura do fonte
#
# Fonte única: versão e nome da ferramenta vivem no orquestrador de
# cada alvo, e o build só propaga. Ter esses valores em dois
# lugares é como não ter nenhum dos dois.
#
# O orquestrador é sempre a última lib da lista do alvo, o que
# também documenta a ordem de dependência.
# ------------------------------------------------------------

# orquestrador_de <alvo>
orquestrador_de() {
	local alvo="$1"
	local -n libs="PA_LIBS_${alvo}"

	printf 'lib/%s.sh\n' "${libs[-1]}"
}

# ler_var <nome> <arquivo>
ler_var() {
	local nome="$1"
	local arquivo="$2"
	local valor

	valor="$(
		awk -F'"' -v n="^${nome}=" '$0 ~ n {print $2; exit}' "$arquivo"
	)"

	[[ -n "$valor" ]] || erro "não achei ${nome} em ${arquivo}"

	printf '%s\n' "$valor"
}

# ------------------------------------------------------------
# Instaladores embutidos no menu
# ------------------------------------------------------------

# delim_de <alvo>
delim_de() {
	printf '%s_%s\n' "$PA_DELIM_INSTALADOR" "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
}

# marcador_de <alvo>
#
# O comentário que o menu procura para dizer em que linha cada
# instalador começa. É lido em tempo de execução pelo próprio menu,
# então o texto aqui e o de lib/menu_main.sh têm de bater.
marcador_de() {
	local alvo="$1"
	local arq="${PA_SAIDA[$alvo]}"

	printf '# ===== INSTALADOR %s =====\n' "${arq##*/}"
}

# texto_do_menu <alvo> <campo> <valor>
#
# Os textos do menu entram no artefato entre aspas duplas. Aspa,
# cifrão, crase e barra invertida mudariam o sentido da linha gerada,
# então o build recusa em vez de escapar: são textos curtos, escritos
# aqui mesmo, e não há motivo para terem esses caracteres.
texto_do_menu() {
	local alvo="$1" campo="$2" valor="$3"

	[[ -n "$valor" ]] || erro "playahead: falta ${campo} de ${alvo}, em build.sh"

	case "$valor" in
		*\"* | *\$* | *\`* | *\\*)
			erro "playahead: ${campo} de ${alvo} tem aspa, cifrão, crase ou barra invertida"
			;;
	esac

	printf '%s' "$valor"
}

# embutir_instaladores
#
# Escreve cada artefato como heredoc citado dentro de uma função, e
# em seguida a linha que o põe na lista do menu.
# Citado é obrigatório: o conteúdo é código bash cheio de $ e de
# crase, e precisa chegar literal ao arquivo final.
embutir_instaladores() {
	local alvo arq delim versao nome descricao grupo instalado

	for alvo in "${PA_EMBUTIDOS[@]}"; do
		arq="${PA_SAIDA[$alvo]}"
		delim="$(delim_de "$alvo")"

		[[ -f "$arq" ]] ||
			erro "playahead: falta ${arq}; gere os instaladores antes"

		if grep -qF "$delim" "$arq"; then
			erro "playahead: ${arq} contém ${delim}; troque o delimitador"
		fi

		# A versão também entra na linha gerada, entre aspas duplas,
		# e por isso passa por um filtro como os textos: só número, no
		# formato 0.0.0. Um PA_VERSAO com "$(...)" viraria comando no
		# artefato do menu.
		versao="$(ler_var PA_VERSAO "$(orquestrador_de "$alvo")")"
		[[ "$versao" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
			erro "playahead: a versão de ${alvo} não está no formato 0.0.0"

		nome="$(texto_do_menu "$alvo" nome "${PA_MENU_NOME[$alvo]:-}")"
		descricao="$(texto_do_menu "$alvo" descrição "${PA_MENU_DESCRICAO[$alvo]:-}")"
		grupo="$(texto_do_menu "$alvo" grupo "${PA_MENU_GRUPO[$alvo]:-}")"
		instalado="$(texto_do_menu "$alvo" instalado "${PA_MENU_INSTALADO[$alvo]:-}")"

		marcador_de "$alvo"
		printf 'menu_conteudo_%s() {\n' "$alvo"
		printf "\tcat <<'%s'\n" "$delim"
		cat "$arq"
		printf '%s\n' "$delim"
		printf '}\n\n'

		printf 'menu_registrar "%s" "%s" \\\n' "${arq##*/}" "$versao"
		printf '\t"%s" \\\n' "$nome"
		printf '\t"%s" \\\n' "$descricao"
		printf '\t"%s" \\\n' "$grupo"
		printf '\t"%s"\n\n' "$instalado"
	done
}

# verificar_embutidos <arquivo_do_menu>
#
# Prova que cada instalador embutido saiu byte a byte igual ao
# artefato publicado. Mesma verificação do template, e pelo mesmo
# motivo: o menu promete conter exatamente o que as URLs entregam.
verificar_embutidos() {
	local menu="$1"
	local alvo arq delim extraido

	for alvo in "${PA_EMBUTIDOS[@]}"; do
		arq="${PA_SAIDA[$alvo]}"
		delim="$(delim_de "$alvo")"
		extraido="$(mktemp)"

		awk -v d="$delim" '
			index($0, d) && !dentro { dentro = 1; next }
			dentro && $0 == d       { exit }
			dentro                  { print }
		' "$menu" >"$extraido"

		if ! diff -q "$arq" "$extraido" >/dev/null 2>&1; then
			rm -f "$extraido"
			erro "playahead: o ${arq} embutido difere do publicado"
		fi

		info "playahead: ${arq##*/} embutido idêntico ($(wc -l <"$extraido") linhas)"
		rm -f "$extraido"
	done
}

# ------------------------------------------------------------
# Geração
# ------------------------------------------------------------

# gerar <alvo> <arquivo_destino> <build>
gerar() {
	local alvo="$1"
	local destino="$2"
	local build="$3"

	local -n libs="PA_LIBS_${alvo}"

	local template="${PA_TEMPLATE[$alvo]}"

	local orq
	orq="$(orquestrador_de "$alvo")"

	local versao ferramenta
	versao="$(ler_var PA_VERSAO "$orq")"
	ferramenta="$(ler_var PA_FERRAMENTA "$orq")"

	local lib
	for lib in "${libs[@]}"; do
		[[ -f "lib/${lib}.sh" ]] || erro "falta lib/${lib}.sh"
	done

	if [[ -n "$template" ]]; then
		[[ -f "$template" ]] || erro "falta $template"

		if grep -qF "$PA_DELIM" "$template"; then
			erro "o template contém ${PA_DELIM}; troque o delimitador"
		fi
	fi

	{
		# O cabeçalho é o mesmo bloco de licença e aviso que o
		# script imprime na tela, mais os dados de versão. Quem dá
		# `less` vê isso nas primeiras linhas, o que é justamente o
		# ponto daquele passo do tutorial.
		#
		# E, antes de tudo, as instruções do próprio `less`. No
		# teste de 2026-09-30 a pessoa ficou presa dentro dele sem
		# saber que estava num paginador nem como sair. O tutorial
		# manda dar `less` em um arquivo de milhares de linhas, e
		# quem nunca usou um paginador não tem como adivinhar que
		# `q` sai. Custa dez linhas e é a primeira coisa que
		# aparece na tela em todo o fluxo.
		cat <<CABECALHO
#!/usr/bin/env bash
# ============================================================
# VOCÊ ESTÁ LENDO UM ARQUIVO. NADA FOI INSTALADO AINDA.
#
# Se esta tela apareceu depois de um comando \`less\`, é o
# \`less\` que está mostrando o arquivo para você conferir.
#
#   seta para baixo, seta para cima    rolam uma linha
#   Espaço                             rola uma tela
#   q                                  sai e volta para o terminal
#
# Para instalar, aperte q e rode o próximo comando do tutorial.
# ============================================================
# PLAY AHEAD INSTALLER
# ${ferramenta}
# https://playahead.com.br
#
# Versão: ${versao}
# Build:  ${build}
# Fonte:  ${PA_FONTE}
#
# Licença MIT. Consulte o arquivo LICENSE.
#
# AVISO
# Este script altera a configuração do servidor onde é executado:
# instala pacotes, cria containers, volumes e regras de rede.
# Execute apenas em servidor dedicado a esta finalidade e do qual
# você tenha cópia de segurança.
#
# O software é fornecido "como está", sem garantia de qualquer
# espécie. A Play Ahead não se responsabiliza por perda de dados,
# indisponibilidade ou danos decorrentes do uso.
#
# Leia o código antes de executar.
# ============================================================
#
# ARQUIVO GERADO POR build.sh. NÃO EDITE AQUI.
# O código-fonte é modular e vive em lib/*.sh, em ${PA_FONTE}
# ============================================================

set -euo pipefail

CABECALHO

		# As libs, na ordem de dependência. O shebang de cada uma é
		# removido: no meio de um arquivo ele seria só um
		# comentário, mas deixá-lo sugeriria que aquele trecho é
		# executável por conta própria.
		for lib in "${libs[@]}"; do
			printf '# ============================================================\n'
			printf '# lib/%s.sh\n' "$lib"
			printf '# ============================================================\n\n'
			sed '1{/^#!/d}' "lib/${lib}.sh"
			printf '\n'
		done

		# O template do compose, embutido como heredoc citado.
		# Citado é obrigatório: o template está cheio de variáveis
		# do compose que precisam chegar literais ao arquivo final.
		#
		# A base não tem template: os composes do Traefik e do
		# Portainer são gerados em código, porque dependem de
		# valores descobertos em execução.
		if [[ -n "$template" ]]; then
			printf '# ============================================================\n'
			printf '# Template do compose, embutido pelo build.sh\n'
			printf '# ============================================================\n\n'
			printf 'mautic_template_embutido() {\n'
			printf "\tcat <<'%s'\n" "$PA_DELIM"
			cat "$template"
			printf '%s\n' "$PA_DELIM"
			printf '}\n\n'
		fi

		# Os instaladores embutidos, só no menu.
		if [[ "$alvo" == "playahead" ]]; then
			printf '# ============================================================\n'
			printf '# Instaladores embutidos pelo build.sh\n'
			printf '# ============================================================\n\n'
			embutir_instaladores
		fi

		printf '# ============================================================\n'
		printf '# Ponto de entrada\n'
		printf '# ============================================================\n\n'
		printf 'main "$@"\n'
	} >"$destino"

	# A data de build só existe no arquivo gerado. No fonte a
	# variável fica como "desenvolvimento", que é o sinal de que
	# aquilo não é artefato publicado.
	sed -i "s/^PA_BUILD=\"desenvolvimento\"$/PA_BUILD=\"${build}\"/" "$destino"

	grep -q "^PA_BUILD=\"${build}\"$" "$destino" ||
		erro "${alvo}: não consegui injetar a data de build"
}

# ------------------------------------------------------------
# Validação do artefato
# ------------------------------------------------------------

# validar <alvo> <arquivo>
validar() {
	local alvo="$1"
	local arquivo="$2"

	local template="${PA_TEMPLATE[$alvo]}"

	bash -n "$arquivo" || erro "${alvo}: não passa em bash -n"

	if command -v shellcheck >/dev/null 2>&1; then
		shellcheck --format=gcc "$arquivo" ||
			erro "${alvo}: não passa em shellcheck"
		info "${alvo}: shellcheck sem warnings"
	else
		info "${alvo}: shellcheck não encontrado; validação parcial"
	fi

	# Prova de que o artefato roda: --version não toca em nada da
	# máquina e exercita o parse de flags e a concatenação.
	bash "$arquivo" --version >/dev/null ||
		erro "${alvo}: falhou em --version"

	if [[ "$alvo" == "playahead" ]]; then
		verificar_embutidos "$arquivo"
	fi

	[[ -n "$template" ]] || return 0

	# Prova de que o template embutido saiu íntegro, comparando byte
	# a byte com o original.
	#
	# A extração é feita lendo o texto, e não dando `source` no
	# arquivo: o dist termina com a chamada do main, então
	# carregá-lo rodaria o instalador de verdade na máquina de quem
	# está compilando.
	local extraido
	extraido="$(mktemp)"

	awk -v d="$PA_DELIM" '
		index($0, d) && !dentro { dentro = 1; next }
		dentro && $0 == d       { exit }
		dentro                  { print }
	' "$arquivo" >"$extraido"

	if ! diff -q "$template" "$extraido" >/dev/null 2>&1; then
		rm -f "$extraido"
		erro "${alvo}: o template embutido difere de ${template}"
	fi

	info "${alvo}: template idêntico ao original ($(wc -l <"$extraido") linhas)"
	rm -f "$extraido"

	verificar_versoes_template "$template"
}

# verificar_versoes_template <template>
#
# A versão recomendada de cada imagem vive em dois lugares: na
# variável do lib/mautic.sh, que o script usa para mostrar e
# escolher, e no padrão do template, que vale para quem usa o
# compose à mão. Os dois têm de bater. Sem esta conferência, um
# pedido de atualização que trocasse um e esquecesse o outro
# instalaria uma versão e anunciaria outra.
verificar_versoes_template() {
	local template="$1"
	local variavel imagem esperado encontrados

	for variavel in PA_MAUTIC_IMAGEM_RECOMENDADA:MAUTIC_IMAGE PA_MARIADB_IMAGEM:MARIADB_IMAGE; do
		esperado="$(awk -F'"' -v v="${variavel%%:*}=" 'index($0, v) == 1 { print $2; exit }' lib/mautic.sh)"
		[[ -n "$esperado" ]] || erro "falta ${variavel%%:*} em lib/mautic.sh"

		imagem="${variavel##*:}"
		encontrados="$(grep -o "\${${imagem}:-[^}]*}" "$template" | sort -u)"

		if [[ "$encontrados" != "\${${imagem}:-${esperado}}" ]]; then
			erro "o template usa ${encontrados//$'\n'/ }, mas ${variavel%%:*} é ${esperado}"
		fi
	done

	info "versões do template iguais às de lib/mautic.sh"
}

# ------------------------------------------------------------
# Temas guardados
# ------------------------------------------------------------

# variaveis_do_tema <arquivo>
#
# Os nomes das variáveis PA_TEMA_ que o arquivo declara, um por linha.
variaveis_do_tema() {
	grep -oE '^PA_TEMA_[A-Z_]+=' "$1" | sort -u
}

# bloco_do_tema <arquivo>
#
# As linhas entre o título "# TEMA" e o "# FIM DO TEMA".
bloco_do_tema() {
	awk '
		$0 == "# TEMA"        { dentro = 1; next }
		$0 == "# FIM DO TEMA" { dentro = 0 }
		dentro                { print }
	' "$1"
}

# conferir_tema <rótulo para a mensagem>
#
# Lê do stdin as linhas de um tema e para o build se alguma for mais
# que um dado. Um tema é uma lista de variáveis PA_TEMA_ com valor
# literal, e mais nada.
#
# Importa porque tema vira código. O docs/visual/previa.sh carrega o
# arquivo do tema, e trocar de tema é copiar o bloco para dentro do
# lib/ui.sh, que roda como root na VPS de quem instala. Antes desta
# conferência (auditoria de 2026-11-12), um tema com "$(comando)"
# passava no build, e um número entre aspas simples, que parece
# texto, também executava: as margens e a largura entram em conta.
#
# O que uma linha pode ser:
#
#   vazia, ou comentário
#   PA_TEMA_NOME=123                número puro
#   PA_TEMA_NOME="texto"            sem aspa, cifrão, crase nem barra
#                                   invertida dentro
#   PA_TEMA_NOME=("a" "b")          lista numa linha, de textos assim
#   PA_TEMA_NOME=(                  lista em várias linhas: cada item
#       'texto'                     entre aspas simples, numa linha só
#   )
#
# E mais duas regras de tipo: o que entra em conta (largura, margens e
# as chaves de 0 ou 1) tem de ser número puro, e cor tem de ser só
# dígito e ponto e vírgula.
conferir_tema() {
	local rotulo="$1"
	local texto='[^"$`\\]*'
	local re_numero='^(PA_TEMA_[A-Z_]+)=[0-9]+$'
	local re_texto="^(PA_TEMA_[A-Z_]+)=\"${texto}\"\$"
	local re_lista="^(PA_TEMA_[A-Z_]+)=\\((\"${texto}\" ?)+\\)\$"
	local re_abre='^(PA_TEMA_[A-Z_]+)=\($'
	local re_item="^[[:space:]]+'[^']*'\$"
	local re_cor='^PA_TEMA_COR_[A-Z_]+="[0-9;]+"$'
	local re_conta='^PA_TEMA_(LARGURA|MARGEM_[A-Z]+|[A-Z]+_LINHA|[A-Z]+_FECHA)$'

	local linha nome na_lista=0 n=0
	while IFS= read -r linha || [[ -n "$linha" ]]; do
		n=$((n + 1))

		if [[ "$na_lista" -eq 1 ]]; then
			if [[ "$linha" == ")" ]]; then
				na_lista=0
			elif [[ ! "$linha" =~ $re_item ]]; then
				erro "${rotulo}: linha ${n} do tema não é um item de lista entre aspas simples"
			fi
			continue
		fi

		[[ -z "$linha" || "$linha" == "#"* ]] && continue

		if [[ "$linha" =~ $re_abre ]]; then
			na_lista=1
			continue
		fi

		if [[ "$linha" =~ $re_numero ]]; then
			continue
		fi

		if [[ "$linha" =~ $re_texto || "$linha" =~ $re_lista ]]; then
			nome="${BASH_REMATCH[1]}"

			if [[ "$nome" =~ $re_conta ]]; then
				erro "${rotulo}: ${nome} entra em conta, e tem de ser número puro, sem aspas"
			fi

			if [[ "$nome" == PA_TEMA_COR_* && ! "$linha" =~ $re_cor ]]; then
				erro "${rotulo}: ${nome} tem de ser só dígito e ponto e vírgula"
			fi

			continue
		fi

		erro "${rotulo}: linha ${n} do tema não é uma variável PA_TEMA_ com valor literal"
	done

	[[ "$na_lista" -eq 0 ]] || erro "${rotulo}: lista do tema sem o parêntese de fecho"
}

# verificar_temas
#
# Duas conferências. O bloco TEMA do lib/ui.sh e cada arquivo de
# docs/visual/ têm de ser só dados (ver conferir_tema): o arquivo
# guardado é conferido inteiro, e não só o bloco, porque a prévia o
# carrega inteiro.
#
# E os temas guardados só servem se puderem entrar no lugar do bloco
# do lib/ui.sh. Para isso têm de declarar exatamente as mesmas
# variáveis. Um tema guardado que ficou para trás quando o bloco
# ganhou uma variável nova quebraria no dia da troca, que é justamente
# o dia em que ninguém lembra mais do motivo.
verificar_temas() {
	local tema quantos=0

	[[ -n "$(bloco_do_tema lib/ui.sh)" ]] ||
		erro "não achei o bloco TEMA em lib/ui.sh"

	bloco_do_tema lib/ui.sh | conferir_tema "lib/ui.sh"

	for tema in docs/visual/tema-*.sh; do
		[[ -f "$tema" ]] || continue

		# O primeiro "$tema" é só o nome para a mensagem de erro: o
		# arquivo é lido, e nunca escrito.
		# shellcheck disable=SC2094
		conferir_tema "$tema" <"$tema"

		if [[ "$(variaveis_do_tema "$tema")" != "$(variaveis_do_tema lib/ui.sh)" ]]; then
			erro "${tema} não declara as mesmas variáveis do tema de lib/ui.sh"
		fi

		bash -n "$tema" || erro "${tema}: não passa em bash -n"
		quantos=$((quantos + 1))
	done

	info "tema de lib/ui.sh e ${quantos} de docs/visual: só dados, com as mesmas variáveis"
}

# ------------------------------------------------------------
# Corpo, sem o cabeçalho
#
# Serve para comparar duas builds ignorando a data. Sem isso, todo
# build produziria um diff mesmo sem mudança no fonte, e o
# `git status` viveria sujo.
#
# Só a DATA é ignorada, e só nas duas linhas que o build escreve, no
# formato exato em que ele as escreve. Até 2026-11-11 a função
# apagava qualquer linha que começasse com "PA_BUILD=", e a auditoria
# de segurança mostrou o preço: uma linha
#
#     PA_BUILD="$(comando qualquer)"
#
# acrescentada ao dist/ passava pelo --check como "em dia" e rodava
# como root na VPS de quem baixasse. O --check é o que garante que o
# dist/ saiu do lib/, e a trava dos pedidos da rotina confia nele.
#
# Trocando a data por um marcador, em vez de apagar a linha, uma
# linha a mais ou uma linha fora do formato aparece na comparação.
# ------------------------------------------------------------

corpo() {
	local arquivo="$1"
	local data='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'

	[[ -f "$arquivo" ]] || return 0

	sed -E \
		-e "s/^# Build:  ${data}\$/# Build:  DATA/" \
		-e "s/^PA_BUILD=\"${data}\"\$/PA_BUILD=\"DATA\"/" \
		"$arquivo"
}

# ------------------------------------------------------------
# main
# ------------------------------------------------------------

modo="${1:-gerar}"

case "$modo" in
	gerar | --check) ;;
	*) erro "modo desconhecido: ${modo} (use --check ou nada)" ;;
esac

build="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
defasados=0

verificar_temas

for alvo in "${PA_ALVOS[@]}"; do
	saida="${PA_SAIDA[$alvo]}"

	temporario="$(mktemp)"

	gerar "$alvo" "$temporario" "$build"
	validar "$alvo" "$temporario"

	if [[ "$modo" == "--check" ]]; then
		if [[ ! -f "$saida" ]]; then
			info "${alvo}: ${saida} não existe"
			defasados=1
		elif [[ "$(corpo "$temporario")" != "$(corpo "$saida")" ]]; then
			info "${alvo}: ${saida} está defasado"
			defasados=1
		else
			info "${alvo}: ${saida} está em dia"
		fi

		rm -f "$temporario"
		continue
	fi

	mkdir -p "$(dirname "$saida")"

	# Se só a data mudaria, não reescreve. Regenerar o dist faz
	# parte do commit, e um diff que muda apenas o timestamp faz o
	# revisor procurar uma alteração que não existe.
	if [[ "$(corpo "$temporario")" == "$(corpo "$saida")" ]]; then
		info "${alvo}: já está em dia; nada reescrito"
		rm -f "$temporario"
		continue
	fi

	cp "$temporario" "$saida"
	chmod +x "$saida"
	rm -f "$temporario"

	info "${alvo}: gerado ${saida}"
	info "  versão: $(ler_var PA_VERSAO "$(orquestrador_de "$alvo")")"
	info "  build:  ${build}"
	info "  linhas: $(wc -l <"$saida")"
done

if [[ "$modo" == "--check" ]] && [[ "$defasados" -eq 1 ]]; then
	erro "dist/ está defasado em relação a lib/; rode ./build.sh"
fi
