#!/usr/bin/env python3
"""Engenharia reversa do protocolo BLE da VWAR Loop Life / VWAR MG.

Ferramenta de interoperabilidade pessoal: fala direto com a SUA pulseira, sem o
app G Band, para que os dados fiquem na sua maquina. Segue a mesma metodologia
usada pelos projetos NOOP (Whoop) e Goose/PulseLoop: enumerar o GATT, assinar as
caracteristicas de notificacao, gravar os pacotes crus e so entao decodificar.

Hardware alvo: chipset JieLi JL7013A, BLE 5.3. As "medidas" de acido urico,
lipidios, glicose e pressao arterial sao estimativas de software sem validacao —
esta ferramenta as ignora e busca apenas telemetria real: frequencia cardiaca,
bateria, passos, SpO2 e amostras cruas de PPG/acelerometro.

Requisitos:
    pip install bleak

Fluxo recomendado (4 etapas):

    # 1. Achar a pulseira (nao precisa estar pareada)
    python3 vwarloop/tools/vwar_ble.py scan

    # 2. Mapear todos os servicos e caracteristicas GATT
    python3 vwarloop/tools/vwar_ble.py dump --address AA:BB:CC:DD:EE:FF

    # 3. Gravar os pacotes crus (use a pulseira no pulso; anote a hora e o que
    #    o G Band mostra no mesmo instante — isso e o seu "gabarito")
    python3 vwarloop/tools/vwar_ble.py sniff --address AA:BB... --seconds 120

    # 4. Analisar o log gravado: procura bytes que se comportam como FC/bateria
    python3 vwarloop/tools/vwar_ble.py analyze ~/.vwarloop/ble/sniff-*.jsonl

    # Extra: se a banda expuser o servico padrao de Heart Rate (0x180D), da pra
    #        ler FC ao vivo sem decodificar nada:
    python3 vwarloop/tools/vwar_ble.py hr --address AA:BB... --seconds 60

    # Extra: enviar um comando no canal de escrita e ver o que volta
    python3 vwarloop/tools/vwar_ble.py probe --address AA:BB... \\
        --write-uuid 0000ff01-... --notify-uuid 0000ff02-... --hex "ab000401"
"""
from __future__ import annotations

import argparse
import asyncio
import json
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path

try:
    from bleak import BleakClient, BleakScanner
except ImportError:  # pragma: no cover - dependencia opcional
    print("Este script precisa do pacote 'bleak'. Instale com:\n"
          "    pip install bleak", file=sys.stderr)
    raise SystemExit(1)

LOG_DIR = Path.home() / ".vwarloop" / "ble"
LOG_DIR.mkdir(parents=True, exist_ok=True)

# Nomes que a VWAR/JieLi costuma anunciar. Amplie se a sua aparecer diferente.
NAME_HINTS = ("vwar", "loop", "gband", "g-band", "jl", "mg")

# Servicos GATT padrao — se a banda expuser algum destes, nao ha o que decodificar.
STANDARD = {
    "0000180d-0000-1000-8000-00805f9b34fb": "Heart Rate (padrao)",
    "00002a37-0000-1000-8000-00805f9b34fb": "Heart Rate Measurement",
    "0000180f-0000-1000-8000-00805f9b34fb": "Battery Service (padrao)",
    "00002a19-0000-1000-8000-00805f9b34fb": "Battery Level",
    "0000180a-0000-1000-8000-00805f9b34fb": "Device Information",
    "00001800-0000-1000-8000-00805f9b34fb": "Generic Access",
    "00001801-0000-1000-8000-00805f9b34fb": "Generic Attribute",
}


# ---------------------------------------------------------------- scan -----
async def cmd_scan(args):
    print(f"Procurando dispositivos BLE por {args.seconds}s...\n")
    devices = await BleakScanner.discover(timeout=args.seconds, return_adv=True)
    rows = []
    for dev, adv in devices.values():
        name = (dev.name or adv.local_name or "").strip()
        likely = any(h in name.lower() for h in NAME_HINTS) if name else False
        rows.append((likely, adv.rssi or -999, dev.address, name or "(sem nome)",
                     list(adv.service_uuids or [])))
    rows.sort(key=lambda r: (not r[0], -r[1]))

    if not rows:
        print("Nenhum dispositivo encontrado. Verifique se o Bluetooth do PC esta "
              "ligado e se a pulseira NAO esta conectada ao celular\n"
              "(o G Band segura a conexao e impede o PC de conectar).")
        return
    print(f"{'':2} {'RSSI':>5}  {'ENDERECO':<18} NOME")
    print("-" * 70)
    for likely, rssi, addr, name, uuids in rows:
        mark = ">>" if likely else "  "
        print(f"{mark} {rssi:>5}  {addr:<18} {name}")
        if likely and uuids:
            print(f"{'':27}servicos anunciados: {', '.join(uuids)}")
    print("\n'>>' = nome bate com VWAR/Loop/G Band. Use o endereco com:\n"
          f"    python3 {sys.argv[0]} dump --address <ENDERECO>")


# ---------------------------------------------------------------- dump -----
async def cmd_dump(args):
    print(f"Conectando em {args.address}...\n")
    async with BleakClient(args.address, timeout=args.timeout) as client:
        print(f"Conectado. MTU={getattr(client, 'mtu_size', '?')}\n")
        writables, notifiables = [], []

        for service in client.services:
            std = STANDARD.get(service.uuid.lower(), "")
            print(f"SERVICO {service.uuid}"
                  f"{'  [' + std + ']' if std else '  [proprietario]'}")
            for ch in service.characteristics:
                props = ",".join(ch.properties)
                stdc = STANDARD.get(ch.uuid.lower(), "")
                print(f"   CARACT {ch.uuid}  ({props})"
                      f"{'  [' + stdc + ']' if stdc else ''}")
                if "read" in ch.properties:
                    try:
                        val = await client.read_gatt_char(ch)
                        print(f"          leitura: {val.hex(' ')}"
                              f"   ascii={_ascii(val)}")
                    except Exception as e:
                        print(f"          leitura falhou: {type(e).__name__}")
                if {"notify", "indicate"} & set(ch.properties):
                    notifiables.append(ch.uuid)
                if {"write", "write-without-response"} & set(ch.properties):
                    writables.append(ch.uuid)
            print()

        print("=" * 70)
        print("RESUMO — o que interessa para a proxima etapa")
        print("=" * 70)
        print("Canais de NOTIFICACAO (a banda envia dados por aqui — Tx):")
        for u in notifiables:
            print(f"   {u}{'   <- padrao: ' + STANDARD[u.lower()] if u.lower() in STANDARD else ''}")
        print("\nCanais de ESCRITA (voce manda comandos por aqui — Rx):")
        for u in writables:
            print(f"   {u}")
        print("\nProximo passo — gravar o trafego com a pulseira no pulso:")
        print(f"    python3 {sys.argv[0]} sniff --address {args.address} --seconds 120")
        print("\nDica de metodo: enquanto grava, anote a hora exata e o que o app\n"
              "G Band mostra (ex.: 22:31 FC=82, bateria=64%). Esse gabarito e o que\n"
              "permite localizar o byte certo no passo 'analyze'.")


def _ascii(b: bytes) -> str:
    return "".join(chr(c) if 32 <= c < 127 else "." for c in b)


# --------------------------------------------------------------- sniff -----
async def cmd_sniff(args):
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    out = LOG_DIR / f"sniff-{stamp}.jsonl"
    count = 0
    started = datetime.now()

    def make_cb(uuid):
        def cb(_, data: bytearray):
            nonlocal count
            count += 1
            t = (datetime.now() - started).total_seconds()
            rec = {"t": round(t, 3), "uuid": uuid, "len": len(data),
                   "hex": data.hex(), "ascii": _ascii(bytes(data))}
            with out.open("a") as f:
                f.write(json.dumps(rec) + "\n")
            print(f"[{t:7.2f}s] {uuid[4:8]}  {len(data):>3}B  {data.hex(' ')}"
                  f"   {_ascii(bytes(data))}")
        return cb

    print(f"Conectando em {args.address}...")
    async with BleakClient(args.address, timeout=args.timeout) as client:
        print("Conectado. Assinando canais de notificacao...\n")
        subscribed = []
        for service in client.services:
            for ch in service.characteristics:
                if not ({"notify", "indicate"} & set(ch.properties)):
                    continue
                if args.uuid and ch.uuid.lower() != args.uuid.lower():
                    continue
                try:
                    await client.start_notify(ch, make_cb(ch.uuid))
                    subscribed.append(ch.uuid)
                    print(f"   assinado: {ch.uuid}")
                except Exception as e:
                    print(f"   falhou:   {ch.uuid} ({type(e).__name__})")

        if not subscribed:
            print("\nNenhum canal de notificacao pode ser assinado. Algumas bandas so\n"
                  "comecam a transmitir depois de um comando de handshake no canal de\n"
                  "escrita — use o subcomando 'probe' para testar bytes iniciais.")
            return

        print(f"\nGravando por {args.seconds}s em {out}")
        print("Use a pulseira no pulso. Mexa o braco, fique parado, faca uma medicao\n"
              "manual no G Band — variar o estado ajuda a separar os campos.\n"
              "Ctrl+C para parar antes.\n")
        try:
            await asyncio.sleep(args.seconds)
        except asyncio.CancelledError:
            pass
        for u in subscribed:
            try:
                await client.stop_notify(u)
            except Exception:
                pass

    print(f"\n{count} pacotes gravados em {out}")
    print(f"Analise com:\n    python3 {sys.argv[0]} analyze {out}")


# ------------------------------------------------------------- analyze -----
def cmd_analyze(args):
    """Heuristicas sobre o log: agrupa por formato e procura bytes plausiveis.

    Nao adivinha o protocolo por voce — reduz o espaco de busca e mostra quais
    posicoes de byte se comportam como frequencia cardiaca, bateria ou contador.
    """
    path = Path(args.logfile)
    records = [json.loads(l) for l in path.read_text().splitlines() if l.strip()]
    if not records:
        print("Log vazio.")
        return

    by_shape = defaultdict(list)
    for r in records:
        payload = bytes.fromhex(r["hex"])
        header = payload[0] if payload else -1
        by_shape[(r["uuid"], r["len"], header)].append(payload)

    print(f"{len(records)} pacotes, {len(by_shape)} formatos distintos "
          f"(agrupados por uuid + tamanho + primeiro byte)\n")

    for (uuid, length, header), packets in sorted(
            by_shape.items(), key=lambda kv: -len(kv[1])):
        print("=" * 72)
        print(f"UUID {uuid}   tamanho {length}B   header 0x{header:02x}   "
              f"{len(packets)} pacotes")
        print("-" * 72)
        for p in packets[:3]:
            print(f"   exemplo: {p.hex(' ')}")

        # Perfil por posicao de byte: constante, contador ou variavel.
        print(f"\n   {'pos':>3} {'min':>4} {'max':>4} {'distintos':>9}  perfil")
        for i in range(length):
            col = [p[i] for p in packets if len(p) > i]
            if not col:
                continue
            lo, hi, uniq = min(col), max(col), len(set(col))
            tags = []
            if uniq == 1:
                tags.append("constante (marcador/tipo)")
            else:
                if _is_counter(col):
                    tags.append("contador/sequencia")
                if 40 <= lo and hi <= 200 and uniq > 2:
                    tags.append("FAIXA DE FC PLAUSIVEL (40-200 bpm)")
                if 0 <= lo and hi <= 100 and uniq > 1:
                    tags.append("faixa 0-100 (bateria/SpO2/percentual)")
                if hi > 200 and uniq > 4:
                    tags.append("byte alto — provavel parte de int16")
            print(f"   {i:>3} {lo:>4} {hi:>4} {uniq:>9}  {'; '.join(tags) or 'variavel'}")

        # Candidatos a inteiros de 16 bits (passos, calorias, timestamps).
        print("\n   pares de 16 bits com variacao (candidatos a passos/calorias):")
        found = False
        for i in range(length - 1):
            le = [int.from_bytes(p[i:i+2], "little") for p in packets if len(p) > i+1]
            be = [int.from_bytes(p[i:i+2], "big") for p in packets if len(p) > i+1]
            for label, vals in (("LE", le), ("BE", be)):
                if len(set(vals)) > 2 and max(vals) < 65000 and _monotonic_ish(vals):
                    print(f"      bytes {i}-{i+1} {label}: {vals[:6]} ... "
                          f"(cresce — pode ser passos/tempo)")
                    found = True
        if not found:
            print("      nenhum obvio.")
        print()

    print("=" * 72)
    print("COMO FECHAR A DECODIFICACAO")
    print("=" * 72)
    print("""
1. Pegue seu gabarito (hora + valor mostrado no G Band). Ache no log os pacotes
   daquele instante (campo "t" e o tempo desde o inicio da gravacao).
2. Procure a posicao de byte cujo valor bate com o numero do gabarito. Ex.: se
   as 22:31 o G Band dizia 82 bpm, procure um byte valendo 82 (0x52) numa
   posicao marcada como "FAIXA DE FC PLAUSIVEL".
3. Confirme com um segundo ponto: suba a FC (30 agachamentos), grave de novo e
   veja se o MESMO byte subiu junto. Um acerto e coincidencia; dois e o campo.
4. Escreva o parser em `parse_packet()` abaixo e registre o mapeamento em
   vwarloop/tools/PROTOCOL.md para nao perder o conhecimento.
5. Bateria e SpO2 seguem a mesma receita (faixa 0-100). Passos costumam ser
   int16/int32 little-endian que so cresce.
""")


def _is_counter(col: list[int]) -> bool:
    if len(col) < 4:
        return False
    steps = {(b - a) % 256 for a, b in zip(col, col[1:])}
    return len(steps) == 1 and steps != {0}


def _monotonic_ish(vals: list[int]) -> bool:
    if len(vals) < 4:
        return False
    ups = sum(1 for a, b in zip(vals, vals[1:]) if b >= a)
    return ups >= 0.9 * (len(vals) - 1)


# ------------------------------------------------------------------ hr -----
HR_MEASUREMENT = "00002a37-0000-1000-8000-00805f9b34fb"
BATTERY_LEVEL = "00002a19-0000-1000-8000-00805f9b34fb"


def parse_hr_measurement(data: bytes) -> dict:
    """Decodifica o 0x2A37 padrao (Bluetooth SIG Heart Rate Measurement).

    Se a banda expuser este servico, FC e intervalos RR vem prontos — sem
    engenharia reversa. Os intervalos RR sao o insumo do RMSSD (HRV real).
    """
    flags = data[0]
    idx = 1
    if flags & 0x01:  # FC em uint16
        hr = int.from_bytes(data[idx:idx+2], "little")
        idx += 2
    else:             # FC em uint8
        hr = data[idx]
        idx += 1
    energy = None
    if flags & 0x08:  # campo de energia gasta presente
        energy = int.from_bytes(data[idx:idx+2], "little")
        idx += 2
    rr = []
    if flags & 0x10:  # intervalos RR presentes (unidade 1/1024 s)
        while idx + 1 < len(data):
            rr.append(int.from_bytes(data[idx:idx+2], "little") / 1024 * 1000)
            idx += 2
    return {"hr": hr, "energy": energy, "rr_ms": [round(x, 1) for x in rr]}


def rmssd(rr_ms: list[float]) -> float | None:
    """RMSSD — a metrica de HRV. Raiz da media dos quadrados das diferencas
    sucessivas entre intervalos RR. E isso que WHOOP e Oura reportam como HRV."""
    if len(rr_ms) < 2:
        return None
    diffs = [b - a for a, b in zip(rr_ms, rr_ms[1:])]
    return round((sum(d * d for d in diffs) / len(diffs)) ** 0.5, 1)


async def cmd_hr(args):
    rr_buffer: list[float] = []
    print(f"Conectando em {args.address}...")
    async with BleakClient(args.address, timeout=args.timeout) as client:
        chars = {c.uuid.lower() for s in client.services for c in s.characteristics}
        if HR_MEASUREMENT not in chars:
            print("\nEsta banda NAO expoe o servico padrao de Heart Rate (0x180D).\n"
                  "Use os subcomandos 'dump' e 'sniff' para decodificar o protocolo\n"
                  "proprietario da JieLi.")
            return

        if BATTERY_LEVEL in chars:
            try:
                b = await client.read_gatt_char(BATTERY_LEVEL)
                print(f"Bateria: {b[0]}%")
            except Exception:
                pass

        def cb(_, data: bytearray):
            m = parse_hr_measurement(bytes(data))
            rr_buffer.extend(m["rr_ms"])
            del rr_buffer[:-120]  # janela deslizante ~2 min
            h = rmssd(rr_buffer)
            line = f"FC {m['hr']:>3} bpm"
            if m["rr_ms"]:
                line += f"   RR {m['rr_ms']}"
            if h is not None:
                line += f"   RMSSD(janela) {h} ms"
            print(line)

        await client.start_notify(HR_MEASUREMENT, cb)
        print(f"Lendo FC ao vivo por {args.seconds}s. Ctrl+C para parar.\n")
        try:
            await asyncio.sleep(args.seconds)
        except asyncio.CancelledError:
            pass
        await client.stop_notify(HR_MEASUREMENT)

    h = rmssd(rr_buffer)
    if h is not None:
        print(f"\nRMSSD da sessao: {h} ms  ({len(rr_buffer)} intervalos RR)")
        print("Registre no app: aba Check-in, campo HRV.")
    else:
        print("\nA banda nao enviou intervalos RR — so da para calcular HRV real "
              "se ela expuser esse campo.")


# --------------------------------------------------------------- probe -----
async def cmd_probe(args):
    """Manda bytes no canal de escrita e mostra o que volta pelo de notificacao.

    Muitas bandas JieLi so comecam a transmitir depois de um handshake. Sequencias
    tipicas para testar: ab00 0401, fe01 0100, 0102 0000. Descubra a real capturando
    o trafego do G Band (Android: HCI snoop log em Opcoes do desenvolvedor).
    """
    payload = bytes.fromhex(args.hex.replace(" ", ""))
    got = []

    def cb(_, data: bytearray):
        got.append(bytes(data))
        print(f"   <- {data.hex(' ')}   {_ascii(bytes(data))}")

    async with BleakClient(args.address, timeout=args.timeout) as client:
        await client.start_notify(args.notify_uuid, cb)
        print(f"   -> {payload.hex(' ')}")
        await client.write_gatt_char(args.write_uuid, payload,
                                     response=not args.no_response)
        await asyncio.sleep(args.wait)
        await client.stop_notify(args.notify_uuid)

    print(f"\n{len(got)} respostas." if got else
          "\nSem resposta. Tente outra sequencia, o outro canal de escrita, "
          "ou --no-response.")


# ---------------------------------------------------------------- main -----
def parse_packet(uuid: str, payload: bytes) -> dict | None:
    """Preencha aqui depois de decodificar o seu protocolo.

    Quando 'analyze' apontar as posicoes certas, escreva o parser e documente o
    achado em PROTOCOL.md. Exemplo do formato final:

        if uuid == "0000ff02-..." and payload[0] == 0xAB and len(payload) == 8:
            return {"hr": payload[4], "battery": payload[5],
                    "steps": int.from_bytes(payload[6:8], "little")}
    """
    return None


def main():
    p = argparse.ArgumentParser(
        description="Engenharia reversa BLE da pulseira VWAR Loop Life / MG.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("scan", help="procura pulseiras BLE por perto")
    s.add_argument("--seconds", type=float, default=8.0)

    for name, help_ in (("dump", "lista servicos e caracteristicas GATT"),
                        ("sniff", "grava os pacotes de notificacao"),
                        ("hr", "le FC/RR ao vivo (servico padrao 0x180D)")):
        sp = sub.add_parser(name, help=help_)
        sp.add_argument("--address", required=True, help="MAC ou UUID do dispositivo")
        sp.add_argument("--timeout", type=float, default=20.0)
        if name == "sniff":
            sp.add_argument("--seconds", type=float, default=120.0)
            sp.add_argument("--uuid", help="assinar so esta caracteristica")
        if name == "hr":
            sp.add_argument("--seconds", type=float, default=60.0)

    a = sub.add_parser("analyze", help="analisa um log gravado com 'sniff'")
    a.add_argument("logfile")

    pr = sub.add_parser("probe", help="escreve bytes e observa a resposta")
    pr.add_argument("--address", required=True)
    pr.add_argument("--write-uuid", required=True)
    pr.add_argument("--notify-uuid", required=True)
    pr.add_argument("--hex", required=True, help='ex.: "ab000401"')
    pr.add_argument("--wait", type=float, default=5.0)
    pr.add_argument("--no-response", action="store_true")
    pr.add_argument("--timeout", type=float, default=20.0)

    args = p.parse_args()
    if args.cmd == "analyze":
        cmd_analyze(args)
        return
    fn = {"scan": cmd_scan, "dump": cmd_dump, "sniff": cmd_sniff,
          "hr": cmd_hr, "probe": cmd_probe}[args.cmd]
    try:
        asyncio.run(fn(args))
    except KeyboardInterrupt:
        print("\nInterrompido.")


if __name__ == "__main__":
    main()
