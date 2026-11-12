#!/usr/bin/env python3
# testes/vps/pty-rodar.py
#
# Roda um comando num terminal de verdade (pty) e responde às perguntas
# como uma pessoa faria. Serve para testar na VPS o que só existe com
# terminal: as perguntas, o Ctrl-C, o menu e as cores. A tela inteira
# fica gravada num arquivo, com os códigos de cor.
#
# Uso, como root na VPS:
#
#     python3 pty-rodar.py --log /root/tela.log \
#         --resposta "Posso atualizar?=s" \
#         -- bash mautic7.sh --atualizar
#
# Cada --resposta é "texto esperado=o que digitar", e elas são dadas na
# ordem. O Enter vai junto. Respostas especiais:
#
#     =^C       manda Ctrl-C quando o texto aparecer
#     =^HUP     simula a queda do terminal (SIGHUP no grupo do comando)
#     =^TERM    mata o grupo do comando com SIGTERM
#
# Rode desligado da sessão SSH (setsid nohup) quando o comando for
# demorado: numa VPS de 1 vCPU a carga pode derrubar a conexão.

import argparse
import fcntl
import os
import pty
import re
import select
import signal
import struct
import sys
import termios
import time


def limpa(dados):
    texto = dados.decode(errors="replace")
    texto = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", texto)
    return texto.replace("\r", "")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--log", required=True)
    p.add_argument("--tempo", type=int, default=2400)
    p.add_argument("--colunas", type=int, default=80)
    p.add_argument("--linhas", type=int, default=40)
    p.add_argument("--resposta", action="append", default=[])
    p.add_argument("--sem-cor", action="store_true")
    p.add_argument("comando", nargs=argparse.REMAINDER)
    a = p.parse_args()

    comando = a.comando[1:] if a.comando[:1] == ["--"] else a.comando
    if not comando:
        sys.exit("falta o comando, depois de --")

    passos = []
    for r in a.resposta:
        espera, _, digita = r.partition("=")
        passos.append((espera, digita))

    pid, fd = pty.fork()
    if pid == 0:
        # Devolve ao normal os sinais que chegam ignorados. Um processo
        # lançado em segundo plano (com "&", ou com nohup) herda o
        # Ctrl-C e a queda do terminal ignorados, e o bash não deixa um
        # script voltar a tratar um sinal que já nasceu ignorado: o ^C
        # deste roteiro não teria efeito nenhum no comando testado.
        # Visto em 2026-11-12: o instalador ficou parado na pergunta,
        # com o "^C" na tela.
        for sinal in (signal.SIGINT, signal.SIGQUIT, signal.SIGHUP):
            signal.signal(sinal, signal.SIG_DFL)

        os.environ["TERM"] = "xterm-256color"
        if a.sem_cor:
            os.environ["NO_COLOR"] = "1"
        os.execvp(comando[0], comando)

    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", a.linhas, a.colunas, 0, 0))

    log = open(a.log, "wb")
    saida = b""
    inicio = 0
    i = 0
    t0 = time.time()

    while time.time() - t0 < a.tempo:
        pronto, _, _ = select.select([fd], [], [], 0.3)
        if pronto:
            try:
                dados = os.read(fd, 65536)
            except OSError:
                break
            if not dados:
                break
            saida += dados
            log.write(dados)
            log.flush()

        if i < len(passos) and passos[i][0] in limpa(saida[inicio:]):
            espera, digita = passos[i]
            time.sleep(1)
            if digita == "^C":
                os.write(fd, b"\x03")
            elif digita in ("^HUP", "^TERM"):
                sinal = signal.SIGHUP if digita == "^HUP" else signal.SIGTERM
                os.killpg(os.getpgid(pid), sinal)
            else:
                os.write(fd, digita.encode() + b"\n")
            inicio = len(saida)
            print(f"{time.time() - t0:6.0f}s  {espera!r} -> {digita!r}", flush=True)
            i += 1

    try:
        _, estado = os.waitpid(pid, 0)
        codigo = os.waitstatus_to_exitcode(estado)
    except ChildProcessError:
        codigo = "?"

    print(
        f"saiu com {codigo} | respostas dadas: {i} de {len(passos)} | "
        f"{int(time.time() - t0)} s",
        flush=True,
    )


if __name__ == "__main__":
    main()
