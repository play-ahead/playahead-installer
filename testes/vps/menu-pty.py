# testes/vps/menu-pty.py
#
# Roda o menu (playahead.sh) num terminal de verdade (pty) e responde as
# perguntas como uma pessoa faria: base, depois Mautic, depois sai. A tela
# inteira fica em /root/teste-menu.log. Foi assim que a instalação pelo
# menu foi testada na VPS em 2026-10-27.
#
# Uso, como root na VPS, na pasta onde está o playahead.sh:
#
#     python3 menu-pty.py
#
# Troque os domínios e o e-mail em "passos" antes de usar. Rode desligado
# da sessão SSH (setsid nohup), porque numa VPS de 1 vCPU a carga do
# download pode derrubar a conexão.

import os, pty, time, re, select
def limpa(b): return re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", b.decode(errors="replace")).replace("\r", "")
passos = [
  ("Número da opção", b"1\n"),
  ("E-mail para o certificado SSL", b"admin@playahead.com.br\n"),
  ("Subdomínio do Portainer", b"portainer.demo.agenciaalemdoobvio.com\n"),
  ("Posso começar?", b"\n"),
  ("Número da opção", b"2\n"),
  ("Domínio do Mautic", b"mautic.demo.agenciaalemdoobvio.com\n"),
  ("E-mail para entrar no Mautic", b"admin@playahead.com.br\n"),
  ("Os valores acima estão corretos?", b"\n"),
  ("Posso começar?", b"\n"),
  ("Número da opção", b"0\n"),
]
pid, fd = pty.fork()
if pid == 0:
    os.chdir("/root"); os.environ["TERM"] = "xterm-256color"
    os.execvp("bash", ["bash", "playahead.sh"])
log = open("/root/teste-menu.log", "wb")
saida = b""; ini = 0; i = 0; t0 = time.time()
while time.time() - t0 < 2400:
    r,_,_ = select.select([fd],[],[],0.3)
    if r:
        try: d = os.read(fd, 65536)
        except OSError: break
        if not d: break
        saida += d; log.write(d); log.flush()
    if i < len(passos) and passos[i][0] in limpa(saida[ini:]):
        time.sleep(1); os.write(fd, passos[i][1]); ini = len(saida)
        print(f"{time.time()-t0:6.0f}s  respondeu: {passos[i][0]}", flush=True); i += 1
_, st = os.waitpid(pid, 0)
print("menu saiu com", os.waitstatus_to_exitcode(st), "| respostas dadas:", i, "de", len(passos), "| tempo total", int(time.time()-t0), "s")
