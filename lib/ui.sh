#!/usr/bin/env bash
# shellcheck shell=bash
#
# ============================================================
# lib/ui.sh
# Cores, mensagens, perguntas e esperas.
#
# Esta é uma biblioteca: carregar o arquivo não executa nada,
# só define funções. Quem liga as cores é ui_init, chamada pelo
# orquestrador depois do parse das flags.
#
# Depois do build.sh este arquivo vira um trecho do
# dist/mautic7.sh e passa a dividir o escopo global com as
# outras libs. Daí duas regras que valem para o arquivo todo:
#
#   1. Todo nome público leva prefixo ui_ ou PA_.
#   2. Nada de `return` fora de função e nada de `readonly` no
#      topo. Num arquivo concatenado isso deixa de ser código
#      de biblioteca e vira código de script, onde `return`
#      é erro de sintaxe.
#
# Toda mensagem passa por ui_linha. Quando o log de execução
# for decidido, é o único ponto que precisa mudar.
# ============================================================

# ============================================================
# TEMA
#
# A cara do instalador está toda neste bloco: o logo, as cores, os
# símbolos, a moldura e o formato dos títulos. Trocar o visual é
# mexer só aqui. O resto do arquivo desenha a tela a partir destas
# variáveis, e nenhuma outra lib escolhe cor ou caractere.
#
# Há outros dois temas prontos em docs/visual/, cada um com este
# mesmo bloco preenchido de outro jeito. Para trocar, copie o bloco
# de lá por cima deste, do "TEMA" ao "FIM DO TEMA", e rode
# ./build.sh. Para ver um tema na tela sem instalar nada:
#
#     bash docs/visual/previa.sh docs/visual/tema-1-marca-na-moldura.sh
#
# Tema em uso: 2, letras em bloco entre duas linhas.
# ============================================================

# O logo, como aparece na tela. Está escrito com os mesmos caracteres
# que vão para o terminal, para quem lê este arquivo antes de rodar
# ver o desenho, e não uma lista de códigos.
PA_TEMA_LOGO=(
	'█▀█ █   █▀█ █ █   █▀█ █ █ █▀▀ █▀█ █▀▄'
	'█▀▀ █   █▀█ ▀█▀   █▀█ █▀█ █▀▀ █▀█ █ █'
	'▀   ▀▀▀ ▀ ▀  ▀    ▀ ▀ ▀ ▀ ▀▀▀ ▀ ▀ ▀▀'
)

# O nome por extenso, para o tema em que o logo é um desenho e o nome
# precisa vir escrito ao lado. Aqui o logo já é o nome.
PA_TEMA_NOME=""

# Como o logo é apresentado:
#   linhas   entre uma linha em cima e outra embaixo
#   caixa    dentro de uma moldura fechada, com o nome ao lado
#   barra    com uma barra vertical à esquerda
PA_TEMA_CABECALHO="linhas"

# O quadro final, com o endereço e as senhas: "linhas" ou "caixa".
PA_TEMA_QUADRO="linhas"

# Largura do que é desenhado, sem a margem. Com a margem e as bordas
# cabe nas 80 colunas de um terminal padrão.
PA_TEMA_LARGURA=68

# Margens, em colunas: onde começam as linhas e as molduras, os
# títulos, e o que acontece dentro de cada etapa. O detalhe de cada
# coisa fica duas colunas depois.
PA_TEMA_MARGEM_MOLDURA=2
PA_TEMA_MARGEM_TITULO=3
PA_TEMA_MARGEM_ITEM=3

# Título de etapa. {n} é o número da etapa e {t} o total. O que vem
# antes do título sai na cor da marca; o que vem depois, apagado. O
# teste fixo lê estas duas linhas para conferir o contador.
PA_TEMA_ETAPA_ANTES="[{n}/{t}] "
PA_TEMA_ETAPA_DEPOIS=""

# 1 para passar uma linha embaixo do título de etapa.
PA_TEMA_ETAPA_LINHA=0

# Título sem número: o que vem antes dele, e se leva linha embaixo.
PA_TEMA_SECAO_ANTES=""
PA_TEMA_SECAO_LINHA=1

# Lista do menu: o número de cada item ({n}), e se a lista fecha com
# outra linha.
PA_TEMA_LISTA_NUMERO="{n}"
PA_TEMA_LISTA_FECHA=1

# Símbolos: o passo em andamento, os três resultados, e a marca do
# que veio da pessoa na tela de confirmação.
PA_TEMA_SIMBOLO_PASSO="›"
PA_TEMA_SIMBOLO_OK="✓"
PA_TEMA_SIMBOLO_AVISO="!"
PA_TEMA_SIMBOLO_ERRO="✗"
PA_TEMA_SIMBOLO_INFORMADO=">"

# Peças das linhas e da moldura. Os cantos na ordem: de cima à
# esquerda, de cima à direita, de baixo à esquerda, de baixo à
# direita.
PA_TEMA_TRACO="─"
PA_TEMA_LADO="│"
PA_TEMA_CANTOS=("┌" "┐" "└" "┘")
PA_TEMA_BARRA="▌"

# Cores, em códigos ANSI: o que vai entre "ESC[" e "m". São poucas de
# propósito. A da marca fica só na identidade: o logo, as linhas do
# cabeçalho, o contador de etapas e os números do menu. Verde,
# amarelo e vermelho dizem o resultado de cada passo, e mais nada. O
# resto é texto normal, em negrito ou apagado.
#
# A cor da marca e o cinza do texto apagado só existem na paleta de
# 256 cores. Terminal que não a anuncia recebe as "BASICA", das 8
# cores. Sem terminal, ou com NO_COLOR, não sai cor nenhuma.
PA_TEMA_COR_MARCA="38;5;135"
PA_TEMA_COR_MARCA_BASICA="0;35"
PA_TEMA_COR_FRACA="38;5;245"
PA_TEMA_COR_FRACA_BASICA="0;90"
PA_TEMA_COR_OK="0;32"
PA_TEMA_COR_AVISO="0;33"
PA_TEMA_COR_ERRO="1;31"
PA_TEMA_COR_DESTAQUE="1"

# ============================================================
# FIM DO TEMA
# ============================================================

# ------------------------------------------------------------
# Estado
# ------------------------------------------------------------

# Preenchidas por ui_init, a partir das cores do tema. Vazias por
# padrão para que o arquivo funcione mesmo se alguém esquecer de
# inicializar, e para a saída sem terminal não levar código nenhum.
PA_COR_RESET=""
PA_COR_MARCA=""
PA_COR_OK=""
PA_COR_AVISO=""
PA_COR_ERRO=""
PA_COR_FRACA=""
PA_COR_DESTAQUE=""

# 1 quando dá para perguntar: --yes ausente e stdin é terminal.
PA_INTERATIVO=0

# O que o cabeçalho diz embaixo do logo, no lugar do nome da
# ferramenta. Só o menu preenche. Nasce vazia aqui, e não só no menu,
# para um valor herdado do ambiente de quem roda nunca chegar ao
# cabeçalho de um instalador: é ele que diz ao suporte qual instalador
# rodou.
PA_TITULO=""

# Modo do terminal, guardado pelo ui_init e devolvido no EXIT.
PA_TERMINAL_MODO=""

# Contador de etapas. Cada instalador diz o total com ui_etapas, e
# cada ui_etapa avança um. Com o total em zero, que é o caso do menu,
# ui_etapa vira um título sem número.
PA_UI_ETAPAS_TOTAL=0
PA_UI_ETAPA_N=0

# As margens do tema, já em espaços, e a largura das linhas. Quem
# preenche é ui_tema_aplicar.
PA_UI_M_MOLDURA=""
PA_UI_M_TITULO=""
PA_UI_M_ITEM=""
PA_UI_M_DETALHE=""
PA_UI_LARGURA_LINHA=0

# ui_tema_aplicar
#
# Calcula o que é derivado do tema. Roda quando este arquivo é
# carregado e de novo no ui_init, para valer também quando um tema é
# carregado por cima deste, como faz o docs/visual/previa.sh.
ui_tema_aplicar() {
	printf -v PA_UI_M_MOLDURA '%*s' "$PA_TEMA_MARGEM_MOLDURA" ''
	printf -v PA_UI_M_TITULO '%*s' "$PA_TEMA_MARGEM_TITULO" ''
	printf -v PA_UI_M_ITEM '%*s' "$PA_TEMA_MARGEM_ITEM" ''
	printf -v PA_UI_M_DETALHE '%*s' "$((PA_TEMA_MARGEM_ITEM + 2))" ''

	# As linhas que separam as etapas fecham na mesma coluna do
	# cabeçalho. Na caixa isso inclui as duas bordas.
	PA_UI_LARGURA_LINHA="$PA_TEMA_LARGURA"
	if [[ "$PA_TEMA_CABECALHO" == "caixa" ]]; then
		PA_UI_LARGURA_LINHA=$((PA_TEMA_LARGURA + 2))
	fi
}

ui_tema_aplicar

# Coluna onde os valores do resumo começam, em caracteres.
PA_RESUMO_COLUNA=20

# ------------------------------------------------------------
# Inicialização
# ------------------------------------------------------------

# ui_init [nao_interativo]
#
# Liga cores quando a saída é um terminal, respeitando a
# convenção NO_COLOR (https://no-color.org).
#
# O modo interativo cai sozinho quando stdin não é terminal.
# Sem isso, um `curl | bash` (que o tutorial desaconselha mas
# que alguém vai tentar) leria EOF em cada pergunta e adotaria
# todos os defaults em silêncio.
ui_init() {
	local nao_interativo="${1:-0}"

	ui_tema_aplicar

	if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
		local esc=$'\033['
		PA_COR_RESET="${esc}0m"
		PA_COR_OK="${esc}${PA_TEMA_COR_OK}m"
		PA_COR_AVISO="${esc}${PA_TEMA_COR_AVISO}m"
		PA_COR_ERRO="${esc}${PA_TEMA_COR_ERRO}m"
		PA_COR_DESTAQUE="${esc}${PA_TEMA_COR_DESTAQUE}m"

		# A cor da marca só existe na paleta de 256 cores. Terminal
		# que não a anuncia recebe a das 8 cores básicas.
		if [[ "${TERM}" == *256color* ]]; then
			PA_COR_MARCA="${esc}${PA_TEMA_COR_MARCA}m"
			PA_COR_FRACA="${esc}${PA_TEMA_COR_FRACA}m"
		else
			PA_COR_MARCA="${esc}${PA_TEMA_COR_MARCA_BASICA}m"
			PA_COR_FRACA="${esc}${PA_TEMA_COR_FRACA_BASICA}m"
		fi
	fi

	if [[ "$nao_interativo" == "1" ]]; then
		PA_INTERATIVO=0
	elif [[ -t 0 ]]; then
		PA_INTERATIVO=1
	else
		PA_INTERATIVO=0
	fi

	# Guarda o modo do terminal e promete devolvê-lo.
	#
	# O ui_descartar_entrada troca o modo por alguns
	# milissegundos e devolve em seguida. O trap cobre a morte
	# dentro dessa janela: um Ctrl-C ali deixaria o terminal sem
	# edição de linha depois de o script sair, e a pessoa não
	# teria como saber por que o Backspace parou de funcionar.
	if ui_interativo; then
		PA_TERMINAL_MODO="$(stty -g 2>/dev/null || true)"
		[[ -n "$PA_TERMINAL_MODO" ]] &&
			trap ui_restaurar_terminal EXIT
	fi
}

# ------------------------------------------------------------
# Ctrl-C
# ------------------------------------------------------------

# Etapa em andamento, guardada por ui_passo e ui_secao, e o que o
# tratador do Ctrl-C precisa saber para dizer algo útil.
PA_UI_ETAPA=""
PA_UI_ALTEROU=0
PA_UI_DICA_INTERRUPCAO=()
PA_UI_FD_TELA=1

# ui_tratar_interrupcao <linhas da dica...>
#
# Cada instalador chama depois do ui_init, com a dica do que fazer
# para continuar. O menu não chama: o filho que ele roda morre com
# 130, e o menu já mostra "interrompido" e volta para a lista.
#
# Até 2026-10-22 o Ctrl-C matava o instalador sem imprimir nada:
# medido num pty, a tela terminava no "^C". A pessoa não sabia em
# que etapa tinha parado, nem se rodar de novo era seguro.
ui_tratar_interrupcao() {
	PA_UI_DICA_INTERRUPCAO=("$@")

	# Cópia da saída de agora, que é a tela. Ver ui_mensagem_interrupcao.
	exec {PA_UI_FD_TELA}>&1

	trap ui_ao_interromper INT
}

# ui_marcar_alteracao
#
# Chamada pelo instalador quando começa a mexer na máquina. Antes
# disso, o Ctrl-C pode dizer que nada foi alterado.
ui_marcar_alteracao() {
	PA_UI_ALTEROU=1
}

# ui_ao_interromper
#
# Sai com 130, o código de quem morre por SIGINT, para o menu
# continuar reconhecendo a interrupção. O trap de EXIT do ui_init
# roda em seguida e devolve o terminal.
ui_ao_interromper() {
	trap - INT
	ui_mensagem_interrupcao >&"$PA_UI_FD_TELA" 2>&1
	exit 130
}

# ui_mensagem_interrupcao
#
# Escrita sempre na cópia da saída guardada por
# ui_tratar_interrupcao, e não na saída do momento. O trap roda
# com os redirecionamentos do comando interrompido ainda ativos:
# medido em 2026-10-22, o Ctrl-C caiu dentro do ui_aguardar_ate,
# que roda a checagem com >/dev/null, e a mensagem inteira foi
# para o /dev/null. A tela terminava no "^C", com saída 130.
ui_mensagem_interrupcao() {
	ui_vazio
	ui_erro "Interrompido (Ctrl-C)${PA_UI_ETAPA:+ em: ${PA_UI_ETAPA}}"

	if [[ "$PA_UI_ALTEROU" -eq 0 ]]; then
		ui_detalhe "Nada foi alterado nesta máquina ainda."
		ui_detalhe "Rode de novo quando quiser."
	else
		ui_detalhe "Nada foi desfeito: o que já foi feito continua aí."
		local linha
		for linha in "${PA_UI_DICA_INTERRUPCAO[@]}"; do
			ui_detalhe "$linha"
		done
	fi
	ui_vazio
}

# ui_restaurar_terminal
#
# Devolve o modo salvo pelo ui_init. Roda no EXIT, e por isso
# não imprime nada: no caminho de erro a mensagem útil já foi
# impressa pelo ui_fatal, e ruído depois dela atrapalha.
ui_restaurar_terminal() {
	[[ -n "${PA_TERMINAL_MODO:-}" ]] || return 0
	stty "$PA_TERMINAL_MODO" 2>/dev/null || true
	return 0
}

# ui_interativo
#
# Verdadeiro quando ainda dá para perguntar alguma coisa.
ui_interativo() {
	[[ "$PA_INTERATIVO" == "1" ]]
}

# ------------------------------------------------------------
# Primitiva de saída
# ------------------------------------------------------------

# ui_linha <texto...>
#
# Único ponto de escrita do módulo.
#
# Só o ui_fatal vai para stderr. Todo o resto fica no stdout,
# inclusive ui_aviso e ui_erro.
#
# A razão é ordem. Aviso e erro quase sempre vêm seguidos de
# ui_info e ui_detalhe explicando o que aconteceu, e separar os
# dois fluxos faz as linhas trocarem de lugar assim que a saída é
# redirecionada para um arquivo: a linha mais importante aparece
# no meio da explicação dela mesma.
#
# Visto duas vezes. Primeiro na tabela de detecção do Traefik,
# onde o aviso aparecia depois dos próprios detalhes, o que moveu
# ui_aviso para o stdout. Depois na verificação de roteamento, com
# ui_erro, o que fechou a regra.
#
# O ui_fatal é a exceção porque o bloco dele é inteiro no stderr,
# cabeçalho e ajuda juntos, então não se parte.
ui_linha() {
	printf '%s\n' "$*"
}

ui_linha_erro() {
	printf '%s\n' "$*" >&2
}

# ------------------------------------------------------------
# Mensagens
# ------------------------------------------------------------

# As margens vêm do tema. O que acontece dentro de uma etapa começa
# sempre na mesma coluna, e o detalhe de cada coisa duas colunas
# depois. Assim a marca de resultado fica sempre no mesmo lugar, e o
# texto dela alinha com o detalhe de baixo.

ui_info() {
	ui_linha "${PA_UI_M_ITEM}$*"
}

# ui_passo <texto...>
#
# O que o instalador está fazendo agora, dentro de uma etapa.
ui_passo() {
	PA_UI_ETAPA="$*"
	ui_linha "${PA_UI_M_ITEM}${PA_COR_MARCA}${PA_TEMA_SIMBOLO_PASSO}${PA_COR_RESET} ${PA_COR_DESTAQUE}$*${PA_COR_RESET}"
}

ui_ok() {
	ui_linha "${PA_UI_M_ITEM}${PA_COR_OK}${PA_TEMA_SIMBOLO_OK}${PA_COR_RESET} $*"
}

ui_aviso() {
	ui_linha "${PA_UI_M_ITEM}${PA_COR_AVISO}${PA_TEMA_SIMBOLO_AVISO}${PA_COR_RESET} $*"
}

# ui_erro <texto...>
#
# Diagnóstico que NÃO encerra o script, e por isso vai no stdout,
# junto com as linhas de ui_info e ui_detalhe que o explicam.
#
# Isso corrige um defeito de ordem: com a mensagem no stderr e a
# explicação no stdout, quem redireciona a saída para arquivo
# recebe os dois blocos embaralhados, e a linha mais importante
# aparece no meio da explicação dela mesma. Foi visto ao testar a
# verificacao de roteamento.
#
# A regra passou a ser simples: só o ui_fatal escreve no stderr,
# porque só ele encerra o script.
ui_erro() {
	ui_linha "${PA_UI_M_ITEM}${PA_COR_ERRO}${PA_TEMA_SIMBOLO_ERRO}${PA_COR_RESET} $*"
}

# ui_detalhe <texto...>
#
# Informação secundária: caminho de arquivo, valor detectado,
# comando sugerido. Recuada e apagada de propósito, para não
# competir com a mensagem principal.
ui_detalhe() {
	ui_linha "${PA_UI_M_DETALHE}${PA_COR_FRACA}$*${PA_COR_RESET}"
}

ui_vazio() {
	ui_linha ""
}

# ui_repetir <caractere> <vezes>
ui_repetir() {
	local preenchido
	printf -v preenchido '%*s' "$2" ''
	printf '%s' "${preenchido// /$1}"
}

ui_separador() {
	ui_linha "${PA_UI_M_MOLDURA}${PA_COR_FRACA}$(ui_repetir "$PA_TEMA_TRACO" "$PA_UI_LARGURA_LINHA")${PA_COR_RESET}"
}

# ui_numeros <formato> <n> [total]
#
# Troca {n} e {t} de um formato do tema pelos números.
ui_numeros() {
	local texto="$1"
	texto="${texto//\{n\}/$2}"
	texto="${texto//\{t\}/${3:-}}"
	printf '%s' "$texto"
}

# ui_secao <titulo>
#
# Título sem número, para o que acontece dentro de uma etapa ou fora
# da contagem: o que foi encontrado no Traefik, uma instalação que já
# existia.
ui_secao() {
	PA_UI_ETAPA="$1"
	ui_vazio
	ui_linha "${PA_UI_M_TITULO}${PA_COR_MARCA}${PA_TEMA_SECAO_ANTES}${PA_COR_RESET}${PA_COR_DESTAQUE}$1${PA_COR_RESET}"
	if [[ "$PA_TEMA_SECAO_LINHA" -eq 1 ]]; then
		ui_separador
	fi
}

# ui_etapas <total>
#
# Diz quantas etapas este instalador tem e zera a contagem. O total
# é do caminho inteiro: uma etapa que não tem nada a fazer ainda
# aparece, dizendo isso, para o contador nunca pular número.
ui_etapas() {
	PA_UI_ETAPAS_TOTAL="$1"
	PA_UI_ETAPA_N=0
}

# ui_etapa <titulo>
#
# Título de etapa, com o contador no formato do tema.
ui_etapa() {
	if [[ "$PA_UI_ETAPAS_TOTAL" -eq 0 ]]; then
		ui_secao "$1"
		return 0
	fi

	PA_UI_ETAPA_N=$((PA_UI_ETAPA_N + 1))
	PA_UI_ETAPA="$1"

	local antes depois
	antes="$(ui_numeros "$PA_TEMA_ETAPA_ANTES" "$PA_UI_ETAPA_N" "$PA_UI_ETAPAS_TOTAL")"
	depois="$(ui_numeros "$PA_TEMA_ETAPA_DEPOIS" "$PA_UI_ETAPA_N" "$PA_UI_ETAPAS_TOTAL")"

	ui_vazio
	ui_linha "${PA_UI_M_TITULO}${PA_COR_MARCA}${antes}${PA_COR_RESET}${PA_COR_DESTAQUE}$1${PA_COR_RESET}${PA_COR_FRACA}${depois}${PA_COR_RESET}"
	if [[ "$PA_TEMA_ETAPA_LINHA" -eq 1 ]]; then
		ui_separador
	fi
}

# ------------------------------------------------------------
# Resumo
# ------------------------------------------------------------

# ui_largura <texto>
#
# Largura de exibição em caracteres.
#
# Nem `${#texto}` nem o `%-16s` do printf servem: os dois contam
# bytes quando o locale não é UTF-8, e daí todo rótulo acentuado
# desloca a coluna. Em vez de depender do locale da máquina, conta
# removendo os bytes de continuação do UTF-8, os que começam com
# 10xxxxxx, na faixa 0x80 a 0xBF.
ui_largura() {
	LC_ALL=C printf '%s' "$1" | LC_ALL=C tr -d '\200-\277' | LC_ALL=C wc -c
}

# ui_resumo <titulo> [<rotulo> <valor> <origem>]...
#
# A tela de confirmação antes de começar. Existe por dois
# motivos, e os dois são de gente, não de código: pegar domínio
# digitado errado antes de o Let's Encrypt falhar, e dar um
# momento de narrar, no vídeo, o que vai acontecer.
#
# A <origem> de cada linha é uma destas três:
#
#   informado   veio da pessoa, digitado ou por flag
#   detectado   lido desta máquina
#   padrao      valor que o script traz de fábrica
#
# Só o "informado" recebe marca na tela, e a razão vem do teste
# de 2026-09-30: o resumo mostrou um e-mail errado, fruto de
# colagem, e passou batido no meio de dez linhas todas com o
# mesmo peso visual. Detectado e padrão a pessoa não tem como
# conferir; informado é o único grupo em que ela é a fonte, e
# portanto o único em que ela pode achar o erro.
#
# A marca é um caractere, e não só cor, porque cor não existe com
# NO_COLOR nem quando a saída vai para arquivo.
ui_resumo() {
	local titulo="$1"
	shift

	ui_etapa "$titulo"

	local rotulo valor origem preenchimento marca cor reset
	local tem_informado=0

	while [[ "$#" -ge 3 ]]; do
		rotulo="$1"
		valor="${2//[[:cntrl:]]/}"
		origem="$3"
		shift 3

		preenchimento=$((PA_RESUMO_COLUNA - $(ui_largura "$rotulo")))
		[[ "$preenchimento" -lt 1 ]] && preenchimento=1

		if [[ "$origem" == "informado" ]]; then
			marca="${PA_TEMA_SIMBOLO_INFORMADO} "
			cor="$PA_COR_DESTAQUE"
			reset="$PA_COR_RESET"
			tem_informado=1
		else
			marca="  "
			cor=""
			reset=""
		fi

		printf '%s%s%s%*s%s%s%s\n' \
			"$PA_UI_M_ITEM" "$marca" "$rotulo" "$preenchimento" "" \
			"$cor" "$valor" "$reset"
	done

	# Sobra de argumento é erro de programação, não de quem roda:
	# alguém passou um par onde o formato pede trio. Falhar alto
	# aqui é melhor que imprimir um resumo incompleto na tela em
	# que a pessoa vai confiar para decidir.
	if [[ "$#" -ne 0 ]]; then
		ui_fatal "ui_resumo recebeu $# argumento(s) sobrando (erro interno)."
	fi

	if [[ "$tem_informado" -eq 1 ]]; then
		ui_vazio
		ui_detalhe "${PA_TEMA_SIMBOLO_INFORMADO} veio de você. Confira estes com atenção."
	fi

	ui_vazio
}

# ui_confirmar_resumo
#
# Pergunta se pode começar, depois do resumo.
#
# O resumo é impresso sempre, inclusive com --yes: ele vale como
# registro do que foi decidido naquela execução. A pergunta é que
# não aparece no modo automático.
ui_confirmar_resumo() {
	ui_interativo || return 0

	if ui_confirmar "Posso começar?" 1; then
		return 0
	fi

	ui_vazio
	ui_info "Nada foi alterado nesta máquina."
	ui_vazio
	exit 0
}

# ------------------------------------------------------------
# Falha
# ------------------------------------------------------------

# ui_fatal <mensagem> [linha_de_ajuda...]
#
# Encerra com código 1. As linhas seguintes à mensagem são
# impressas como detalhe: é onde entra o "como resolver".
#
# Nunca chamar dentro de $( ). Numa substituição de comando o
# exit encerra apenas o subshell e o script segue como se nada
# tivesse acontecido. É por isso que ui_perguntar devolve o
# valor por nameref em vez de imprimir no stdout.
ui_fatal() {
	local mensagem="$1"
	shift

	# Tudo no stderr, inclusive o cabecalho: aqui o bloco inteiro
	# e o erro final, e parti-lo entre dois fluxos embaralha a
	# mensagem com a ajuda dela.
	ui_linha_erro ""
	ui_linha_erro "${PA_UI_M_ITEM}${PA_COR_ERRO}${PA_TEMA_SIMBOLO_ERRO}${PA_COR_RESET} ${mensagem}"

	local ajuda
	for ajuda in "$@"; do
		ui_linha_erro "${PA_UI_M_DETALHE}${PA_COR_FRACA}${ajuda}${PA_COR_RESET}"
	done

	ui_linha_erro ""
	exit 1
}

# ------------------------------------------------------------
# Cabeçalho
# ------------------------------------------------------------

# ui_aviso_legal <margem>
#
# O aviso que o CLAUDE.md exige em toda execução. Em texto corrido,
# fora de qualquer moldura: é para ser lido, e moldura em volta de
# parágrafo atrapalha.
ui_aviso_legal() {
	local m="$1"

	ui_linha "${m}${PA_COR_AVISO}AVISO${PA_COR_RESET}"
	ui_linha "${m}Este script altera a configuração do servidor onde é executado:"
	ui_linha "${m}instala pacotes, cria containers, volumes e regras de rede."
	ui_linha "${m}Execute apenas em servidor dedicado a esta finalidade e do qual"
	ui_linha "${m}você tenha cópia de segurança."
	ui_vazio
	ui_linha "${m}O software é fornecido \"como está\", sem garantia de qualquer"
	ui_linha "${m}espécie. A Play Ahead não se responsabiliza por perda de dados,"
	ui_linha "${m}indisponibilidade ou danos decorrentes do uso."
	ui_vazio
	ui_linha "${m}Leia o código antes de executar."
}

# ui_cabecalho
#
# O logo, o que este arquivo instala, a versão, o site, a licença e o
# aviso. Imprime e faz uma pausa curta, sem pedir confirmação
# digitada: "digite concordo" travaria a instalação automatizada e
# atrapalharia a gravação do vídeo.
#
# O nome da empresa e o CNPJ não aparecem aqui, por decisão do Fabio
# em 2026-11-12. O titular da licença está no arquivo LICENSE, que é
# onde a licença MIT o exige.
#
# São três jeitos de apresentar o logo, e quem escolhe é o tema, em
# PA_TEMA_CABECALHO.
ui_cabecalho() {
	# PA_TITULO só existe no menu, que não é de ferramenta nenhuma.
	local ferramenta="${PA_TITULO:-${PA_FERRAMENTA:-Instalador}}"
	local versao="versão ${PA_VERSAO:-dev}"
	local site="playahead.com.br"
	local licenca="Licença MIT. Consulte o arquivo LICENSE."

	local margem="$PA_UI_M_TITULO"
	local traco i texto

	ui_vazio

	case "$PA_TEMA_CABECALHO" in
		caixa)
			margem="$PA_UI_M_MOLDURA"

			# Ao lado do desenho: o nome por extenso, o que este
			# arquivo instala e a versão, encostados na última linha
			# do logo.
			local ao_lado=() estilo=()
			if [[ -n "$PA_TEMA_NOME" ]]; then
				ao_lado+=("$PA_TEMA_NOME")
				estilo+=("$PA_COR_DESTAQUE")
			fi
			ao_lado+=("$ferramenta" "$versao")
			estilo+=("" "$PA_COR_FRACA")

			local coluna=0 largura
			for i in "${!PA_TEMA_LOGO[@]}"; do
				largura="$(ui_largura "${PA_TEMA_LOGO[i]}")"
				[[ "$largura" -gt "$coluna" ]] && coluna="$largura"
			done
			coluna=$((coluna + 5))

			local altura="${#PA_TEMA_LOGO[@]}"
			[[ "${#ao_lado[@]}" -gt "$altura" ]] && altura="${#ao_lado[@]}"
			local desce=$((altura - ${#ao_lado[@]}))

			traco="$(ui_repetir "$PA_TEMA_TRACO" "$PA_TEMA_LARGURA")"
			ui_linha "${margem}${PA_COR_MARCA}${PA_TEMA_CANTOS[0]}${traco}${PA_TEMA_CANTOS[1]}${PA_COR_RESET}"
			ui_moldura_linha "$PA_TEMA_LARGURA" 1 "" ""

			local desenho lado cor espaco pintado
			for ((i = 0; i < altura; i++)); do
				desenho="${PA_TEMA_LOGO[i]:-}"
				lado=""
				cor=""
				if [[ "$i" -ge "$desce" ]]; then
					lado="${ao_lado[i - desce]}"
					cor="${estilo[i - desce]}"
				fi

				espaco=$((coluna - $(ui_largura "$desenho")))
				printf -v texto '%s%*s%s' "$desenho" "$espaco" '' "$lado"
				printf -v pintado '%s%s%s%*s%s%s%s' \
					"$PA_COR_MARCA" "$desenho" "$PA_COR_RESET" "$espaco" '' \
					"$cor" "$lado" "$PA_COR_RESET"
				ui_moldura_linha "$PA_TEMA_LARGURA" 1 "$texto" "$pintado"
			done

			ui_moldura_linha "$PA_TEMA_LARGURA" 1 "" ""
			ui_linha "${margem}${PA_COR_MARCA}${PA_TEMA_CANTOS[2]}${traco}${PA_TEMA_CANTOS[3]}${PA_COR_RESET}"
			ui_vazio
			ui_linha "${margem}${PA_COR_FRACA}${site}${PA_COR_RESET}"
			ui_linha "${margem}${PA_COR_FRACA}${licenca}${PA_COR_RESET}"
			;;

		barra)
			margem="${PA_UI_M_MOLDURA}  "
			local barra="${PA_UI_M_MOLDURA}${PA_COR_MARCA}${PA_TEMA_BARRA}${PA_COR_RESET}"

			for i in "${!PA_TEMA_LOGO[@]}"; do
				ui_linha "${barra} ${PA_COR_MARCA}${PA_TEMA_LOGO[i]}${PA_COR_RESET}"
			done
			ui_linha "$barra"
			ui_linha "${barra} ${PA_COR_DESTAQUE}${ferramenta}${PA_COR_RESET}"
			ui_linha "${barra} ${PA_COR_FRACA}${versao}${PA_COR_RESET}"
			ui_linha "${barra} ${PA_COR_FRACA}${site}${PA_COR_RESET}"
			ui_linha "${barra} ${PA_COR_FRACA}${licenca}${PA_COR_RESET}"
			;;

		*)
			traco="$(ui_repetir "$PA_TEMA_TRACO" "$PA_TEMA_LARGURA")"
			ui_linha "${PA_UI_M_MOLDURA}${PA_COR_MARCA}${traco}${PA_COR_RESET}"
			ui_vazio
			for i in "${!PA_TEMA_LOGO[@]}"; do
				ui_linha "${margem}${PA_COR_MARCA}${PA_TEMA_LOGO[i]}${PA_COR_RESET}"
			done
			ui_vazio

			# O que este arquivo instala à esquerda, a versão à
			# direita. A versão termina antes do fim da linha o mesmo
			# tanto que o texto começa depois do começo dela.
			local sobra
			sobra=$((PA_TEMA_LARGURA - 2 * (PA_TEMA_MARGEM_TITULO - PA_TEMA_MARGEM_MOLDURA)))
			sobra=$((sobra - $(ui_largura "$ferramenta") - $(ui_largura "$versao")))
			[[ "$sobra" -lt 2 ]] && sobra=2
			printf -v texto '%s%s%s%*s%s%s%s' \
				"$PA_COR_DESTAQUE" "$ferramenta" "$PA_COR_RESET" "$sobra" '' \
				"$PA_COR_FRACA" "$versao" "$PA_COR_RESET"
			ui_linha "${margem}${texto}"

			ui_linha "${PA_UI_M_MOLDURA}${PA_COR_MARCA}${traco}${PA_COR_RESET}"
			ui_linha "${margem}${PA_COR_FRACA}${site}   ${licenca}${PA_COR_RESET}"
			;;
	esac

	ui_vazio
	ui_aviso_legal "$margem"
	ui_vazio

	sleep 3
}

# ------------------------------------------------------------
# Perguntas
#
# Todas devolvem o valor por nameref, não pelo stdout. Assim a
# função roda no mesmo shell e ui_fatal consegue encerrar o
# script de verdade quando falta dado no modo --yes.
# ------------------------------------------------------------

# ui_descartar_entrada
#
# Joga fora o que estiver esperando no stdin.
#
# Existe por causa de colagem. No teste de 2026-09-30 a pessoa
# colou texto numa pergunta, a quebra de linha do começo da
# colagem foi lida como resposta vazia, e a sobra ficou na fila
# do terminal esperando a próxima leitura. Resultado: a resposta
# seguinte nasceu grudada na sobra, e o e-mail do admin foi
# gravado como o domínio mais o e-mail, numa string só.
#
# Descartar antes de cada pergunta é a única defesa que funciona
# aqui, porque quem digita não vê o que ficou na fila. O custo é
# que colar as várias respostas de uma vez deixa de funcionar, e
# esse custo é desejado: era exatamente o que produzia a resposta
# errada em silencio.
#
# Precisa passar o terminal para modo não canônico, e isso não é
# preciosismo: foi medido. Em modo canônico, que é o normal, a
# linha só fica disponível para leitura depois do Enter. Uma
# sobra de colagem sem Enter no fim fica parada no buffer do
# terminal, onde `read -t 0` não a vê, e o descarte não descarta
# nada. Testado num pty: com `read -t 0` sozinho, a sobra
# "testemautic.colado.com" continuou grudando na resposta
# seguinte, exatamente como no teste de 2026-09-30.
#
# Com -icanon cada caractere fica disponível na hora, e a sobra
# parcial aparece para o descarte.
#
# O echo fica ligado de propósito. Se o script morrer entre o
# stty de ida e o de volta, um terminal sem icanon ainda mostra o
# que a pessoa digita; sem echo ela digitaria no escuro. O
# ui_init também registra um trap de EXIT que devolve o modo
# original, para o caso de a morte acontecer aqui dentro.
#
# O contador existe para o laço nunca ser infinito.
ui_descartar_entrada() {
	ui_interativo || return 0

	local modo
	modo="$(stty -g 2>/dev/null)" || return 0

	stty -icanon min 0 time 0 2>/dev/null || {
		stty "$modo" 2>/dev/null
		return 0
	}

	local voltas=0

	# Sem nome de variável: o que for lido cai em REPLY e morre
	# ali. Nomear uma variável só para descartar renderia um
	# aviso de valor não usado, com razão. (E comentario não pode
	# começar com a palavra shellcheck: vira diretiva e quebra o
	# build.)
	while [[ "$voltas" -lt 200 ]] && read -r -t 0 2>/dev/null; do
		read -r -n 4096 -t 0.2 2>/dev/null
		voltas=$((voltas + 1))
	done

	stty "$modo" 2>/dev/null
	return 0
}

# ui_limpar_resposta <var>
#
# Tira da resposta o que não é conteúdo: retorno de carro, que
# vem em toda colagem feita a partir do Windows, tabulação, e
# espaço nas duas pontas.
#
# Um domínio colado com retorno de carro no fim carrega o
# caractere invisível junto. Ele passa pelo validador, porque nem
# todo locale o considera espaço, e chega ao label do Traefik. O
# roteador sobe com um Host que nunca casa, e o domínio devolve
# 404 sem nada no log.
ui_limpar_resposta() {
	local -n _bruta="$1"

	# Retorno de carro, tabulação e quebra de linha, e junto com eles
	# todo caractere de controle. Um ESC colado numa resposta iria
	# para a tela de confirmação e para o quadro final, e ali vira
	# comando para o terminal: limpar a tela, trocar o título da
	# janela.
	_bruta="${_bruta//[[:cntrl:]]/}"

	# Espaço das duas pontas, sem sed e sem subshell.
	_bruta="${_bruta#"${_bruta%%[![:space:]]*}"}"
	_bruta="${_bruta%"${_bruta##*[![:space:]]}"}"
}

# ui_perguntar <var_destino> <texto> [padrao] [funcao_validadora]
#
# A validadora recebe a resposta e devolve 0 quando aceita. Ela
# mesma explica o problema na tela; aqui só repetimos a pergunta.
#
# Sem interação: adota o padrão. Não havendo padrão, é dado que
# falta, e o script para: o comportamento prometido para --yes.
ui_perguntar() {
	local -n _destino="$1"
	local texto="$2"
	local padrao="${3:-}"
	local validadora="${4:-}"

	local rotulo="$texto"
	[[ -n "$padrao" ]] && rotulo+=" ${PA_COR_FRACA}[${padrao}]${PA_COR_RESET}"

	if ! ui_interativo; then
		if [[ -z "$padrao" ]]; then
			ui_fatal \
				"Falta um dado obrigatório: ${texto}" \
				"O modo não interativo não pergunta nada." \
				"Informe o valor por flag e rode de novo."
		fi
		_destino="$padrao"
		return 0
	fi

	local resposta
	while true; do
		ui_descartar_entrada
		printf '%s%s: ' "$PA_UI_M_ITEM" "$rotulo"
		IFS= read -r resposta || resposta=""
		ui_limpar_resposta resposta

		[[ -z "$resposta" ]] && resposta="$padrao"

		if [[ -z "$resposta" ]]; then
			ui_aviso "Este campo é obrigatório."
			continue
		fi

		if [[ -n "$validadora" ]] && ! "$validadora" "$resposta"; then
			continue
		fi

		_destino="$resposta"
		return 0
	done
}

# ui_perguntar_opcional <var_destino> <texto> [funcao_validadora]
#
# Como ui_perguntar, mas Enter também é resposta: devolve 1 e
# deixa a variável vazia. Serve para dado que o script sabe
# dispensar, como o subdomínio do Portainer.
#
# Não trata o modo automático, de propósito. Lá o vazio não seria
# escolha de ninguém, e deixar esta função decidir espalharia a
# regra do --yes por dentro do ui.sh. Quem chama confere
# ui_interativo antes e diz, com o nome da flag na tela, o que
# falta.
ui_perguntar_opcional() {
	local -n _destino_opcional="$1"
	local texto="$2"
	local validadora="${3:-}"

	local resposta
	while true; do
		ui_descartar_entrada
		printf '%s%s %s[Enter pula]%s: ' \
			"$PA_UI_M_ITEM" "$texto" "$PA_COR_FRACA" "$PA_COR_RESET"
		IFS= read -r resposta || resposta=""
		ui_limpar_resposta resposta

		if [[ -z "$resposta" ]]; then
			_destino_opcional=""
			return 1
		fi

		if [[ -n "$validadora" ]] && ! "$validadora" "$resposta"; then
			continue
		fi

		_destino_opcional="$resposta"
		return 0
	done
}

# ui_confirmar <texto> [padrao_sim]
#
# Devolve 0 para sim. Sem interação, adota o padrão em silêncio:
# no modo --yes ninguém está lendo a tela.
ui_confirmar() {
	local texto="$1"
	local padrao_sim="${2:-0}"

	local dica="s/N"
	[[ "$padrao_sim" == "1" ]] && dica="S/n"

	if ! ui_interativo; then
		[[ "$padrao_sim" == "1" ]]
		return $?
	fi

	local resposta
	while true; do
		ui_descartar_entrada
		printf '%s%s %s[%s]%s: ' \
			"$PA_UI_M_ITEM" "$texto" "$PA_COR_FRACA" "$dica" "$PA_COR_RESET"
		IFS= read -r resposta || resposta=""
		ui_limpar_resposta resposta

		case "${resposta,,}" in
			s | sim | y | yes) return 0 ;;
			n | nao | não | no) return 1 ;;
			"") [[ "$padrao_sim" == "1" ]] && return 0 || return 1 ;;
			*) ui_aviso "Responda s ou n." ;;
		esac
	done
}

# ui_escolher <var_destino> <texto> <opcao...>
#
# Menu numerado. Usado quando a máquina tem mais de um Traefik
# ou mais de uma rede candidata: casos em que chutar dá 404
# silencioso, então perguntar é obrigatório.
ui_escolher() {
	local -n _escolhido="$1"
	local texto="$2"
	shift 2
	local opcoes=("$@")

	if [[ "${#opcoes[@]}" -eq 0 ]]; then
		ui_fatal "ui_escolher chamada sem opções (erro interno do instalador)."
	fi

	if [[ "${#opcoes[@]}" -eq 1 ]]; then
		_escolhido="${opcoes[0]}"
		return 0
	fi

	if ! ui_interativo; then
		ui_fatal \
			"Mais de uma opção possível para: ${texto}" \
			"Encontradas: ${opcoes[*]}" \
			"O modo não interativo não escolhe sozinho." \
			"Informe o valor por flag e rode de novo."
	fi

	ui_vazio
	ui_info "$texto"

	local i
	for i in "${!opcoes[@]}"; do
		ui_linha "${PA_UI_M_DETALHE}${PA_COR_MARCA}$(ui_numeros "$PA_TEMA_LISTA_NUMERO" "$((i + 1))")${PA_COR_RESET}  ${opcoes[i]}"
	done

	local resposta
	while true; do
		ui_descartar_entrada
		printf '%sNúmero da opção %s[1]%s: ' \
			"$PA_UI_M_ITEM" "$PA_COR_FRACA" "$PA_COR_RESET"
		IFS= read -r resposta || resposta=""
		ui_limpar_resposta resposta
		[[ -z "$resposta" ]] && resposta=1

		if [[ "$resposta" =~ ^[0-9]+$ ]] &&
			[[ "$resposta" -ge 1 ]] &&
			[[ "$resposta" -le "${#opcoes[@]}" ]]; then
			_escolhido="${opcoes[resposta - 1]}"
			return 0
		fi

		ui_aviso "Escolha um número entre 1 e ${#opcoes[@]}."
	done
}

# ------------------------------------------------------------
# Lista
# ------------------------------------------------------------

# ui_comando <texto...>
#
# Um comando para a pessoa copiar. Recuado, e na cor normal do
# texto: o apagado do ui_detalhe é para o que se lê, não para o que
# se digita.
ui_comando() {
	ui_linha "${PA_UI_M_DETALHE}  $*"
}

# ui_lista <titulo> [<numero> <nome> <estado> <descricao>]...
#
# A lista numerada do menu. Cada item são quatro textos: o número, o
# nome, o estado (por exemplo "instalado", ou vazio) e a descrição.
# O nome sai em negrito e a descrição apagada, em colunas alinhadas
# pelo texto mais comprido de cada uma. A coluna do estado só existe
# quando algum item tem estado.
#
# O item de número 0 é a saída, e vai sem negrito.
ui_lista() {
	local titulo="$1"
	shift

	local numeros=() nomes=() estados=() descricoes=()
	while [[ "$#" -ge 4 ]]; do
		numeros+=("$1")
		nomes+=("$2")
		estados+=("$3")
		descricoes+=("$4")
		shift 4
	done

	if [[ "$#" -ne 0 ]]; then
		ui_fatal "ui_lista recebeu $# argumento(s) sobrando (erro interno)."
	fi

	local i largura coluna_numero=0 coluna_nome=0 coluna_estado=0
	local rotulos=()
	for i in "${!nomes[@]}"; do
		rotulos+=("$(ui_numeros "$PA_TEMA_LISTA_NUMERO" "${numeros[i]}")")

		largura="$(ui_largura "${rotulos[i]}")"
		[[ "$largura" -gt "$coluna_numero" ]] && coluna_numero="$largura"

		largura="$(ui_largura "${nomes[i]}")"
		[[ "$largura" -gt "$coluna_nome" ]] && coluna_nome="$largura"

		largura="$(ui_largura "${estados[i]}")"
		[[ "$largura" -gt "$coluna_estado" ]] && coluna_estado="$largura"
	done

	ui_secao "$titulo"
	if [[ "$PA_TEMA_SECAO_LINHA" -ne 1 ]]; then
		ui_vazio
	fi

	local linha negrito espaco
	for i in "${!nomes[@]}"; do
		negrito="$PA_COR_DESTAQUE"
		[[ "${numeros[i]}" == "0" ]] && negrito=""

		espaco=$((coluna_numero - $(ui_largura "${rotulos[i]}") + 2))
		printf -v linha '%s%s%s%s%*s%s%s%s' \
			"$PA_UI_M_ITEM" "$PA_COR_MARCA" "${rotulos[i]}" "$PA_COR_RESET" \
			"$espaco" '' "$negrito" "${nomes[i]}" "$PA_COR_RESET"

		if [[ -n "${estados[i]}${descricoes[i]}" ]]; then
			espaco=$((coluna_nome - $(ui_largura "${nomes[i]}") + 3))
			printf -v linha '%s%*s' "$linha" "$espaco" ''

			if [[ "$coluna_estado" -gt 0 ]]; then
				espaco=$((coluna_estado - $(ui_largura "${estados[i]}") + 3))
				printf -v linha '%s%s%*s' "$linha" "${estados[i]}" "$espaco" ''
			fi

			linha+="${PA_COR_FRACA}${descricoes[i]}${PA_COR_RESET}"
		fi

		ui_linha "$linha"
	done

	if [[ "$PA_TEMA_LISTA_FECHA" -eq 1 ]]; then
		ui_separador
	else
		ui_vazio
	fi
}

# ------------------------------------------------------------
# Esperas
# ------------------------------------------------------------

# ui_aguardar_ate <descricao> <timeout_seg> <comando...>
#
# Repete o comando até ele passar ou o tempo acabar. Devolve 0
# quando passou.
#
# É a alternativa ao `sleep 120` que o CLAUDE.md proíbe: o
# script espera a condição real, diz na tela o que está
# esperando e desiste num prazo conhecido em vez de travar.
ui_aguardar_ate() {
	local descricao="$1"
	local timeout="$2"
	shift 2

	local intervalo=3
	local decorrido=0

	# Os pontinhos só existem para quem está olhando a tela. Sem
	# terminal eles viram lixo no log, então a linha de progresso é
	# suprimida e fica só o resultado.
	#
	# Num terminal com cor, a linha dos pontinhos é apagada quando a
	# espera acaba, e o resultado ocupa o lugar dela: uma linha por
	# espera, e não duas dizendo a mesma coisa. Sem cor (NO_COLOR) o
	# script não manda código de controle nenhum, e o resultado vai
	# na linha de baixo.
	local animar=0
	local fim_da_linha=$'\n'
	if [[ "$PA_INTERATIVO" == "1" ]]; then
		animar=1
		[[ -n "$PA_COR_RESET" ]] && fim_da_linha=$'\r\033[K'
		printf '%s%s ' "$PA_UI_M_ITEM" "$descricao"
	fi

	while true; do
		if "$@" >/dev/null 2>&1; then
			[[ "$animar" == "1" ]] && printf '%s' "$fim_da_linha"
			ui_ok "${descricao}: pronto em ${decorrido}s"
			return 0
		fi

		if [[ "$decorrido" -ge "$timeout" ]]; then
			[[ "$animar" == "1" ]] && printf '%s' "$fim_da_linha"
			ui_erro "${descricao}: nada respondeu em ${timeout}s"
			return 1
		fi

		[[ "$animar" == "1" ]] && printf '.'
		sleep "$intervalo"
		decorrido=$((decorrido + intervalo))
	done
}

# ------------------------------------------------------------
# Quadro
# ------------------------------------------------------------

# ui_moldura_linha <largura interna> <fechada> <texto sem cor> <texto para a tela>
#
# Uma linha de dentro da moldura. O texto vem duas vezes: sem cor,
# para a conta do espaço que falta até a borda da direita, e como
# vai para a tela. Com a moldura aberta (fechada=0) não há borda dos
# lados nem preenchimento.
ui_moldura_linha() {
	local interna="$1" fechada="$2" simples="$3" colorido="$4"

	if [[ "$fechada" -ne 1 ]]; then
		if [[ -n "$simples" ]]; then
			ui_linha "${PA_UI_M_ITEM}${colorido}"
		else
			ui_vazio
		fi
		return 0
	fi

	local sobra=$((interna - 3 - $(ui_largura "$simples")))
	[[ "$sobra" -lt 0 ]] && sobra=0

	local linha
	printf -v linha '%s%s%s%s   %s%*s%s%s%s' \
		"$PA_UI_M_MOLDURA" "$PA_COR_MARCA" "$PA_TEMA_LADO" "$PA_COR_RESET" \
		"$colorido" "$sobra" '' \
		"$PA_COR_MARCA" "$PA_TEMA_LADO" "$PA_COR_RESET"
	ui_linha "$linha"
}

# ui_colunas
#
# Largura do terminal. Sem terminal, 80.
ui_colunas() {
	local colunas=""
	colunas="$(stty size 2>/dev/null | awk '{print $2}')" || true
	[[ "$colunas" =~ ^[0-9]+$ && "$colunas" -ge 40 ]] || colunas=80
	printf '%s\n' "$colunas"
}

# ui_quadro <titulo> [<linha>]...
#
# O que a pessoa precisa levar da tela: o endereço, o usuário, a
# senha. É o único destaque além do cabeçalho.
#
# Cada linha é um texto, ou "rótulo<TAB>valor", que sai em duas
# colunas com o valor em negrito. Linha vazia vira respiro.
#
# O tema escolhe, em PA_TEMA_QUADRO, entre "linhas" (uma linha em
# cima e outra embaixo) e "caixa" (moldura fechada).
#
# Nada é cortado. Na caixa, se uma linha não cabe, o quadro alarga;
# se o quadro alargado não cabe no terminal, as bordas dos lados
# somem e ficam só a de cima e a de baixo: uma senha partida no meio
# pela moldura seria pior que moldura nenhuma.
ui_quadro() {
	local titulo="${1//[[:cntrl:]]/}"
	shift

	# O que chega aqui pode ter vindo de fora: um e-mail lido do banco
	# numa retomada, um nome detectado no Traefik de outra pessoa.
	# Nenhum caractere de controle vai para a tela. A tabulação que
	# separa o rótulo do valor é guardada antes.
	local linhas=() linha rotulo valor largura
	for linha in "$@"; do
		if [[ "$linha" == *$'\t'* ]]; then
			rotulo="${linha%%$'\t'*}"
			valor="${linha#*$'\t'}"
			linhas+=("${rotulo//[[:cntrl:]]/}"$'\t'"${valor//[[:cntrl:]]/}")
		else
			linhas+=("${linha//[[:cntrl:]]/}")
		fi
	done

	local coluna=0
	local maior
	maior="$(ui_largura "$titulo")"

	for linha in ${linhas[@]+"${linhas[@]}"}; do
		[[ "$linha" == *$'\t'* ]] || continue
		largura="$(ui_largura "${linha%%$'\t'*}")"
		[[ "$largura" -gt "$coluna" ]] && coluna="$largura"
	done

	for linha in ${linhas[@]+"${linhas[@]}"}; do
		if [[ "$linha" == *$'\t'* ]]; then
			largura=$((coluna + 3 + $(ui_largura "${linha#*$'\t'}")))
		else
			largura="$(ui_largura "$linha")"
		fi
		[[ "$largura" -gt "$maior" ]] && maior="$largura"
	done

	local interna="$PA_TEMA_LARGURA"
	[[ $((maior + 6)) -gt "$interna" ]] && interna=$((maior + 6))

	local fechado=1
	[[ "$PA_TEMA_QUADRO" == "caixa" ]] || fechado=0
	[[ $((interna + PA_TEMA_MARGEM_MOLDURA + 2)) -gt "$(ui_colunas)" ]] && fechado=0

	local traco
	if [[ "$fechado" -eq 1 ]]; then
		traco="$(ui_repetir "$PA_TEMA_TRACO" "$interna")"
	else
		traco="$(ui_repetir "$PA_TEMA_TRACO" "$PA_UI_LARGURA_LINHA")"
	fi

	ui_vazio
	if [[ "$fechado" -eq 1 ]]; then
		ui_linha "${PA_UI_M_MOLDURA}${PA_COR_MARCA}${PA_TEMA_CANTOS[0]}${traco}${PA_TEMA_CANTOS[1]}${PA_COR_RESET}"
	else
		ui_linha "${PA_UI_M_MOLDURA}${PA_COR_MARCA}${traco}${PA_COR_RESET}"
	fi

	ui_moldura_linha "$interna" "$fechado" "" ""
	ui_moldura_linha "$interna" "$fechado" "$titulo" "${PA_COR_DESTAQUE}${titulo}${PA_COR_RESET}"
	ui_moldura_linha "$interna" "$fechado" "" ""

	local simples pintado
	for linha in ${linhas[@]+"${linhas[@]}"}; do
		if [[ "$linha" == *$'\t'* ]]; then
			rotulo="${linha%%$'\t'*}"
			valor="${linha#*$'\t'}"
			largura=$((coluna - $(ui_largura "$rotulo") + 3))
			printf -v simples '%s%*s%s' "$rotulo" "$largura" '' "$valor"
			printf -v pintado '%s%*s%s%s%s' \
				"$rotulo" "$largura" '' "$PA_COR_DESTAQUE" "$valor" "$PA_COR_RESET"
			ui_moldura_linha "$interna" "$fechado" "$simples" "$pintado"
		else
			ui_moldura_linha "$interna" "$fechado" "$linha" "$linha"
		fi
	done

	ui_moldura_linha "$interna" "$fechado" "" ""
	if [[ "$fechado" -eq 1 ]]; then
		ui_linha "${PA_UI_M_MOLDURA}${PA_COR_MARCA}${PA_TEMA_CANTOS[2]}${traco}${PA_TEMA_CANTOS[3]}${PA_COR_RESET}"
	else
		ui_linha "${PA_UI_M_MOLDURA}${PA_COR_MARCA}${traco}${PA_COR_RESET}"
	fi
	ui_vazio
}

# ------------------------------------------------------------
# Segredos
# ------------------------------------------------------------

# ui_mascarar <segredo>
#
# Ecoa o valor com o miolo trocado por asteriscos. Serve para
# confirmar na tela que a senha certa foi usada sem imprimir a
# senha, e para o dia em que o log de execução existir.
ui_mascarar() {
	local segredo="$1"
	local tamanho="${#segredo}"

	if [[ "$tamanho" -le 8 ]]; then
		printf '%s\n' "********"
		return 0
	fi

	printf '%s********%s\n' "${segredo:0:3}" "${segredo: -2}"
}
