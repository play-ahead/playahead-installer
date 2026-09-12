#!/usr/bin/env bash
# shellcheck shell=bash
#
# ============================================================
# lib/portas.sh
# Descoberta de portas em escuta.
#
# Depende de lib/ui.sh.
#
# Vive fora de lib/checks.sh porque só o instalador de base
# precisa disto: quem decide se 80 e 443 estão livres é quem vai
# subir o Traefik. Um instalador de ferramenta chega numa máquina
# onde o proxy já ocupa as duas, legitimamente, e carregar esta
# cadeia inteira no artefato dele seria peso morto.
#
# É também o único arquivo que instala pacote fora do módulo de
# base propriamente dito, e a exceção está documentada em
# portas_instalar_iproute2.
# ============================================================

# Arquivos do procfs. Existem como variável para os testes
# poderem apontar o parser para exemplos.
PA_PORTAS_PROC_TCP=("/proc/net/tcp" "/proc/net/tcp6")

# portas_ferramenta
#
# Escolhe como listar portas em escuta, na ordem de preferência.
#
# O `ss` vem no iproute2 e está em toda imagem Ubuntu Server que
# se conhece, mas "que se conhece" não é garantia: imagem enxuta
# de provedor às vezes corta o pacote, e aí a checagem mais
# importante do cenário 1 falharia em silêncio, deixando o
# Traefik subir contra uma porta ocupada.
#
# O último recurso é /proc/net/tcp, que faz parte do procfs e
# existe em qualquer Linux. Por isso a cadeia praticamente nunca
# chega a lugar nenhum.
portas_ferramenta() {
	if command -v ss >/dev/null 2>&1; then
		printf 'ss\n'
	elif command -v netstat >/dev/null 2>&1; then
		printf 'netstat\n'
	elif [[ -r "${PA_PORTAS_PROC_TCP[0]}" ]]; then
		printf 'proc\n'
	else
		printf '\n'
	fi
}

# portas_ocupada <porta> <ferramenta>
#
# Devolve 0 quando alguém está escutando na porta.
portas_ocupada() {
	local porta="$1"
	local ferramenta="$2"

	case "$ferramenta" in
		ss)
			ss -ltn "sport = :${porta}" 2>/dev/null | grep -q LISTEN
			;;
		netstat)
			netstat -ltn 2>/dev/null |
				awk -v p="$porta" '
					NR > 2 {
						n = split($4, a, ":")
						if (a[n] == p) { encontrou = 1; exit }
					}
					END { exit !encontrou }
				'
			;;
		proc)
			portas_ocupada_proc "$porta"
			;;
		*)
			return 1
			;;
	esac
}

# portas_ocupada_proc <porta>
#
# Lê o procfs direto. O endereço local vem como hexadecimal
# ("00000000:0050"), e 0A é o estado LISTEN. Precisa olhar tcp e
# tcp6: um serviço que escuta só em IPv6 ocupa a porta do mesmo
# jeito.
portas_ocupada_proc() {
	local porta="$1"

	local hex
	printf -v hex '%04X' "$porta"

	local arquivo
	for arquivo in "${PA_PORTAS_PROC_TCP[@]}"; do
		[[ -r "$arquivo" ]] || continue

		if awk -v p="$hex" '
			$4 == "0A" {
				split($2, a, ":")
				if (a[2] == p) { encontrou = 1; exit }
			}
			END { exit !encontrou }
		' "$arquivo"; then
			return 0
		fi
	done

	return 1
}

# portas_quem_ocupa <porta> <ferramenta>
#
# Melhor esforço para nomear o processo. Serve só para a
# mensagem de erro: saber que "a porta 80 está ocupada" não
# ajuda ninguém, saber que é o apache2 resolve o problema.
portas_quem_ocupa() {
	local porta="$1"
	local ferramenta="$2"

	local quem=""

	case "$ferramenta" in
		ss)
			quem="$(ss -ltnp "sport = :${porta}" 2>/dev/null |
				awk 'NR > 1 {print $NF; exit}')"
			;;
		netstat)
			quem="$(netstat -ltnp 2>/dev/null |
				awk -v p="$porta" '
					NR > 2 {
						n = split($4, a, ":")
						if (a[n] == p) { print $NF; exit }
					}
				')"
			;;
	esac

	if [[ -z "$quem" ]]; then
		quem="processo não identificado"
		[[ "$ferramenta" == "proc" ]] &&
			quem+=" (instale o iproute2 para ver o nome)"
	fi

	printf '%s\n' "$quem"
}

# portas_instalar_iproute2
#
# Exceção à regra de que este módulo não altera a máquina.
#
# Só é chamada quando não existe ss, nem netstat, nem
# /proc/net/tcp legível — combinação que praticamente não
# acontece num Linux. Fica aqui porque a alternativa seria pular
# a checagem de portas, e subir o Traefik contra uma porta
# ocupada é exatamente o tipo de falha silenciosa que este
# projeto tenta evitar.
portas_instalar_iproute2() {
	ui_aviso "Nenhuma forma de listar portas em escuta nesta máquina."
	ui_detalhe "Instalando o iproute2 para conseguir conferir as portas 80 e 443."

	if ! DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1; then
		ui_aviso "Falha ao atualizar a lista de pacotes."
		return 1
	fi

	if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iproute2 >/dev/null 2>&1; then
		ui_aviso "Falha ao instalar o iproute2."
		return 1
	fi

	ui_ok "iproute2 instalado"
}

# portas_livres [pode_instalar]
#
# Só nos cenários 1 e 1.5. No cenário 2 o Traefik ocupa 80 e 443
# legitimamente, e esta checagem é pulada pelo orquestrador.
#
# pode_instalar=1 autoriza a instalação do iproute2 como último
# recurso. O orquestrador só passa 1 no cenário 1, onde a máquina
# vai receber pacote de qualquer jeito.
portas_livres() {
	local pode_instalar="${1:-0}"

	local ferramenta
	ferramenta="$(portas_ferramenta)"

	if [[ -z "$ferramenta" ]]; then
		if [[ "$pode_instalar" == "1" ]] && portas_instalar_iproute2; then
			ferramenta="$(portas_ferramenta)"
		fi
	fi

	if [[ -z "$ferramenta" ]]; then
		ui_fatal \
			"Não consigo conferir se as portas 80 e 443 estão livres." \
			"Não há ss, netstat nem /proc/net/tcp nesta máquina." \
			"Instale o iproute2 e rode de novo:" \
			"" \
			"    sudo apt-get install -y iproute2"
	fi

	[[ "$ferramenta" != "ss" ]] &&
		ui_detalhe "Usando ${ferramenta} para listar portas (ss indisponível)."

	local porta ocupadas=()
	for porta in 80 443; do
		if portas_ocupada "$porta" "$ferramenta"; then
			ocupadas+=("$porta")
		fi
	done

	if [[ "${#ocupadas[@]}" -eq 0 ]]; then
		ui_ok "Portas 80 e 443 livres"
		return 0
	fi

	ui_erro "Portas ocupadas: ${ocupadas[*]}"
	ui_vazio
	ui_info "Quem está ouvindo:"

	for porta in "${ocupadas[@]}"; do
		ui_detalhe "porta ${porta}: $(portas_quem_ocupa "$porta" "$ferramenta")"
	done

	ui_fatal \
		"O Traefik precisa das portas 80 e 443." \
		"Provavelmente há um Apache ou Nginx instalado direto no" \
		"sistema. Pare e desabilite o serviço, ou use uma VPS limpa." \
		"O instalador não desliga serviço de ninguém."
}
