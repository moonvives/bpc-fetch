#!/usr/bin/env python3
"""VWAR Loop — app pessoal de observacao de vida (local-first).

Servidor HTTP autocontido (apenas stdlib) que guarda seus dados de bem-estar
num SQLite local, calcula scores de recuperacao/strain com incerteza explicita
e serve um dashboard (PWA) que roda no desktop e no celular/iPad. Nenhum dado
sai da sua maquina: nao ha servidor remoto, conta ou telemetria.

Uso:
    python3 vwarloop/server.py                 # http://localhost:8787
    VWARLOOP_PORT=9000 python3 vwarloop/server.py
    VWARLOOP_HOME=/caminho python3 vwarloop/server.py   # onde ficam db/config

O coach de IA e opcional e usa o SDK `anthropic` com a SUA chave de API
(variavel ANTHROPIC_API_KEY ou salva nas configuracoes). Sem a chave ou sem o
pacote, todo o resto do app continua funcionando.
"""
from __future__ import annotations

import json
import os
import sqlite3
import statistics
import threading
from datetime import date, datetime, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

# --------------------------------------------------------------------------
# Localizacao de dados — tudo fica no computador do usuario, nada na nuvem.
# --------------------------------------------------------------------------
HOME = Path(os.environ.get("VWARLOOP_HOME", Path.home() / ".vwarloop"))
HOME.mkdir(parents=True, exist_ok=True)
DB_PATH = HOME / "vwarloop.db"
CONFIG_PATH = HOME / "config.json"
STATIC_DIR = Path(__file__).resolve().parent / "static"

PORT = int(os.environ.get("VWARLOOP_PORT", "8787"))

# Campos numericos de check-in que participam dos calculos e dos graficos.
NUMERIC_FIELDS = (
    "sleep_hours", "sleep_quality", "resting_hr", "hrv", "spo2", "temperature",
    "weight", "mood", "energy", "stress", "soreness", "focus",
    "workout_minutes", "workout_intensity", "steps", "water", "caffeine",
    "alcohol",
)

_db_lock = threading.Lock()


# --------------------------------------------------------------------------
# Banco de dados
# --------------------------------------------------------------------------
def get_db() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def init_db() -> None:
    with get_db() as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS entries (
                day               TEXT PRIMARY KEY,   -- 'YYYY-MM-DD'
                sleep_hours       REAL,
                sleep_quality     REAL,   -- 1..5
                resting_hr        REAL,
                hrv               REAL,   -- ms (RMSSD)
                spo2              REAL,   -- %
                temperature       REAL,   -- desvio C ou C
                weight            REAL,
                mood              REAL,   -- 1..5
                energy            REAL,   -- 1..5
                stress            REAL,   -- 1..5 (5 = muito estressado)
                soreness          REAL,   -- 1..5 (5 = muito dolorido)
                focus             REAL,   -- 1..5 (produtividade/foco no dia)
                workout_type      TEXT,
                workout_minutes   REAL,
                workout_intensity REAL,   -- 1..5
                steps             REAL,
                water             REAL,
                caffeine          REAL,
                alcohol           REAL,
                source            TEXT,   -- 'manual' | 'gband' | 'healthkit' | 'ble'
                habits            TEXT,   -- JSON: {"meditou": true, ...}
                notes             TEXT,
                updated_at        TEXT
            )
            """
        )
        conn.commit()


def load_config() -> dict:
    if CONFIG_PATH.exists():
        try:
            return json.loads(CONFIG_PATH.read_text())
        except (json.JSONDecodeError, OSError):
            return {}
    return {}


def save_config(cfg: dict) -> None:
    CONFIG_PATH.write_text(json.dumps(cfg, indent=2, ensure_ascii=False))
    try:
        os.chmod(CONFIG_PATH, 0o600)  # a chave de API mora aqui — restringe leitura
    except OSError:
        pass


# --------------------------------------------------------------------------
# Motor de scores — transparente e explicavel (o diferencial vs. WHOOP/Oura,
# que escondem a formula). Cada componente devolve nota 0..100 + peso.
# --------------------------------------------------------------------------
def _clamp(x: float, lo: float = 0.0, hi: float = 100.0) -> float:
    return max(lo, min(hi, x))


def _baseline(rows: list[sqlite3.Row], field: str, days: int = 30):
    vals = [r[field] for r in rows[:days] if r[field] is not None]
    if not vals:
        return None, None, 0
    mean = statistics.fmean(vals)
    sd = statistics.pstdev(vals) if len(vals) > 1 else 0.0
    return mean, sd, len(vals)


def compute_scores(today: sqlite3.Row, history: list[sqlite3.Row]) -> dict:
    """Loop Score (recuperacao) + strain, com breakdown por componente.

    history = linhas ordenadas do mais recente ao mais antigo (inclui hoje).
    """
    goal = load_config().get("goals", {})
    sleep_goal = float(goal.get("sleep_hours", 8.0))

    components: list[dict] = []

    sh = today["sleep_hours"]
    if sh is not None:
        score = _clamp((sh / sleep_goal) * 100 if sleep_goal else 0)
        components.append({
            "key": "sleep", "label": "Sono", "weight": 0.30, "score": round(score),
            "detail": f"{sh:.1f}h de {sleep_goal:.0f}h alvo",
        })

    rhr = today["resting_hr"]
    base, sd, n = _baseline(history, "resting_hr")
    if rhr is not None and base is not None:
        sd = sd or 3.0
        z = (base - rhr) / sd            # abaixo do baseline = bom
        score = _clamp(50 + z * 20)
        components.append({
            "key": "rhr", "label": "FC repouso", "weight": 0.25, "score": round(score),
            "detail": f"{rhr:.0f} bpm vs. base {base:.0f} (n={n})",
        })

    hrv = today["hrv"]
    base, sd, n = _baseline(history, "hrv")
    if hrv is not None and base is not None:
        sd = sd or 8.0
        z = (hrv - base) / sd            # acima do baseline = bom
        score = _clamp(50 + z * 20)
        components.append({
            "key": "hrv", "label": "HRV", "weight": 0.25, "score": round(score),
            "detail": f"{hrv:.0f} ms vs. base {base:.0f} (n={n})",
        })

    subj = []
    if today["energy"] is not None:
        subj.append((today["energy"] - 1) / 4 * 100)
    if today["stress"] is not None:
        subj.append((5 - today["stress"]) / 4 * 100)
    if today["soreness"] is not None:
        subj.append((5 - today["soreness"]) / 4 * 100)
    if today["sleep_quality"] is not None:
        subj.append((today["sleep_quality"] - 1) / 4 * 100)
    if subj:
        components.append({
            "key": "subjective", "label": "Subjetivo", "weight": 0.20,
            "score": round(_clamp(statistics.fmean(subj))),
            "detail": "energia, estresse, dor, qualidade do sono",
        })

    if components:
        wsum = sum(c["weight"] for c in components)
        loop = round(sum(c["score"] * c["weight"] for c in components) / wsum)
    else:
        loop = None

    # Strain: carga do treino de hoje (escala 0..21, tipo WHOOP).
    strain = None
    mins = today["workout_minutes"]
    inten = today["workout_intensity"]
    if mins:
        inten = inten or 3.0
        strain = round(min(21.0, (mins / 120.0) * (inten / 5.0) * 21.0), 1)

    # Confianca do score: quantos dos 4 componentes estao presentes + baseline.
    present = len(components)
    confidence = "alta" if present >= 3 else "media" if present == 2 else "baixa"

    return {
        "loop_score": loop,
        "components": components,
        "strain": strain,
        "band": _score_band(loop),
        "confidence": confidence,
    }


def _score_band(score) -> str:
    if score is None:
        return "unknown"
    if score >= 75:
        return "good"
    if score >= 50:
        return "warning"
    if score >= 30:
        return "serious"
    return "critical"


def _streak(history: list[sqlite3.Row]) -> int:
    if not history:
        return 0
    days = {r["day"] for r in history}
    streak = 0
    cur = date.today()
    if cur.isoformat() not in days:
        cur = cur - timedelta(days=1)
        if cur.isoformat() not in days:
            return 0
    while cur.isoformat() in days:
        streak += 1
        cur -= timedelta(days=1)
    return streak


# --------------------------------------------------------------------------
# Painel de incerteza / proveniencia — mostrar a incerteza ANTES da IA.
# Para cada metrica: fonte, cobertura (dias com dado nos ultimos 30), lacuna
# desde a ultima medida, e se ha baseline pessoal estabelecido (>= 14 pontos).
# --------------------------------------------------------------------------
def build_provenance(history: list[sqlite3.Row]) -> list[dict]:
    metrics = [
        ("resting_hr", "FC repouso"), ("hrv", "HRV"), ("sleep_hours", "Sono"),
        ("spo2", "SpO2"), ("temperature", "Temperatura"),
    ]
    out = []
    today = date.today()
    window = history[:30]
    for field, label in metrics:
        vals = [r for r in window if r[field] is not None]
        coverage = len(vals)
        last_day = None
        gap_days = None
        for r in history:
            if r[field] is not None:
                last_day = r["day"]
                gap_days = (today - datetime.strptime(r["day"], "%Y-%m-%d").date()).days
                break
        _, _, n = _baseline(history, field)
        if coverage == 0:
            quality = "sem_dados"
        elif n >= 14 and (gap_days is None or gap_days <= 2):
            quality = "confiavel"
        elif coverage >= 5:
            quality = "parcial"
        else:
            quality = "escasso"
        out.append({
            "metric": field, "label": label,
            "coverage_30d": coverage, "gap_days": gap_days,
            "baseline_n": n, "has_baseline": n >= 14,
            "quality": quality,
            "source": "manual",  # atualize para 'healthkit'/'ble' ao integrar
        })
    return out


# --------------------------------------------------------------------------
# Serializacao / persistencia
# --------------------------------------------------------------------------
def row_to_entry(row: sqlite3.Row) -> dict:
    d = dict(row)
    if d.get("habits"):
        try:
            d["habits"] = json.loads(d["habits"])
        except (json.JSONDecodeError, TypeError):
            d["habits"] = {}
    else:
        d["habits"] = {}
    return d


def upsert_entry(payload: dict) -> dict:
    day = payload.get("day") or date.today().isoformat()
    datetime.strptime(day, "%Y-%m-%d")  # valida a data

    fields = {"day": day, "updated_at": datetime.now().isoformat(timespec="seconds")}
    for f in NUMERIC_FIELDS:
        if f in payload and payload[f] not in ("", None):
            fields[f] = float(payload[f])
    if "workout_type" in payload:
        fields["workout_type"] = str(payload["workout_type"])[:120]
    if "source" in payload:
        fields["source"] = str(payload["source"])[:24]
    if "notes" in payload:
        fields["notes"] = str(payload["notes"])[:4000]
    if "habits" in payload and isinstance(payload["habits"], dict):
        fields["habits"] = json.dumps(payload["habits"], ensure_ascii=False)

    cols = ", ".join(fields.keys())
    placeholders = ", ".join("?" for _ in fields)
    updates = ", ".join(f"{k}=excluded.{k}" for k in fields if k != "day")
    with _db_lock, get_db() as conn:
        conn.execute(
            f"INSERT INTO entries ({cols}) VALUES ({placeholders}) "
            f"ON CONFLICT(day) DO UPDATE SET {updates}",
            list(fields.values()),
        )
        conn.commit()
        row = conn.execute("SELECT * FROM entries WHERE day=?", (day,)).fetchone()
    return row_to_entry(row)


def all_entries(limit: int = 400) -> list[sqlite3.Row]:
    with get_db() as conn:
        return conn.execute(
            "SELECT * FROM entries ORDER BY day DESC LIMIT ?", (limit,)
        ).fetchall()


def build_stats() -> dict:
    history = all_entries()
    entries = [row_to_entry(r) for r in history]
    today_iso = date.today().isoformat()
    today_row = history[0] if history and history[0]["day"] == today_iso else None

    scores = compute_scores(today_row, history) if today_row else {
        "loop_score": None, "components": [], "strain": None,
        "band": "unknown", "confidence": "baixa",
    }

    def avg(field, sl):
        vals = [r[field] for r in sl if r[field] is not None]
        return statistics.fmean(vals) if vals else None

    tiles = {}
    for f in ("sleep_hours", "resting_hr", "hrv", "spo2"):
        last7 = avg(f, history[:7])
        prev7 = avg(f, history[7:14])
        delta = (last7 - prev7) if (last7 is not None and prev7 is not None) else None
        tiles[f] = {"value": last7, "delta": delta}

    chrono = list(reversed(entries))[-90:]

    def series(field):
        return [{"day": e["day"], "value": e[field]}
                for e in chrono if e.get(field) is not None]

    # Loop Score historico (recalcula com a janela disponivel ate cada dia).
    asc = list(reversed(history))
    loop_series = []
    for i, r in enumerate(asc):
        window = asc[: i + 1][::-1]  # do dia i para tras, mais recente primeiro
        sc = compute_scores(r, window)
        if sc["loop_score"] is not None:
            loop_series.append({"day": r["day"], "value": sc["loop_score"]})
    loop_series = loop_series[-90:]

    return {
        "today": today_iso,
        "has_today": today_row is not None,
        "scores": scores,
        "tiles": tiles,
        "streak": _streak(history),
        "count": len(history),
        "provenance": build_provenance(history),
        "series": {
            "loop_score": loop_series,
            "sleep_hours": series("sleep_hours"),
            "resting_hr": series("resting_hr"),
            "hrv": series("hrv"),
            "spo2": series("spo2"),
            "strain": [
                {"day": e["day"],
                 "value": round(min(21.0, (e["workout_minutes"] / 120.0)
                          * ((e.get("workout_intensity") or 3.0) / 5.0) * 21.0), 1)}
                for e in chrono if e.get("workout_minutes")
            ],
        },
        "recent": entries[:45],
    }


# --------------------------------------------------------------------------
# Coach de IA — Anthropic Messages API, chave do proprio usuario.
# --------------------------------------------------------------------------
COACH_SYSTEM = """Voce e o coach pessoal de bem-estar do usuario dentro do app \
"VWAR Loop", um app local-first e privado. Fale portugues do Brasil, de forma \
direta, calorosa e pratica — como um treinador que conhece o historico da pessoa.

Voce recebe um resumo dos ultimos ~30 dias (sono, FC de repouso, HRV, SpO2, \
treinos, humor/energia/estresse/foco e um "Loop Score" de recuperacao 0-100 \
calculado a partir de baselines pessoais), alem de um painel de INCERTEZA que \
diz a cobertura e a confiabilidade de cada metrica.

Regras:
- Antes de afirmar algo, olhe a incerteza. Se uma metrica tem cobertura baixa, \
sem baseline ou lacuna grande, diga isso explicitamente e calibre a confianca \
da recomendacao — nunca trate sinal ruidoso como preciso.
- Fundamente cada observacao em numeros concretos e tendencias do resumo.
- Voce NAO e profissional de saude. Nao diagnostique nem prescreva. Para \
preocupacoes medicas, oriente procurar um profissional e fazer exames.
- A pulseira e uma banda barata (chip JieLi JL7013A) sem validacao clinica. \
Trate FC, HRV, SpO2, sono e passos como tendencias uteis. IGNORE e desencoraje \
confiar em "acido urico", "lipidios/colesterol", "glicose" e "pressao arterial" \
estimados por ela — sao estimativas de software sem base cientifica.
- Se o usuario perguntar sobre correlacoes (ex.: melhores horarios para treinar, \
o que afeta foco/produtividade), use os campos de foco, treino e notas para \
sugerir padroes, sempre marcando quando a amostra e pequena.
- Seja acionavel: 2 a 4 recomendacoes concretas ligadas aos dados."""


def run_coach(messages: list[dict], stats: dict) -> dict:
    try:
        import anthropic
    except ImportError:
        return {"error": "no_sdk", "message":
                "O coach precisa do pacote 'anthropic'. Instale com: "
                "pip install anthropic"}

    cfg = load_config()
    api_key = os.environ.get("ANTHROPIC_API_KEY") or cfg.get("anthropic_api_key")
    if not api_key:
        return {"error": "no_key", "message":
                "Nenhuma chave de API configurada. Adicione sua chave da "
                "Anthropic em Configuracoes, ou defina ANTHROPIC_API_KEY."}

    summary = _summarize_for_coach(stats)
    convo = [{"role": m["role"], "content": m["content"]}
             for m in messages if m.get("role") in ("user", "assistant")]
    if not convo:
        return {"error": "empty", "message": "Envie uma mensagem."}

    system = COACH_SYSTEM + "\n\n### Resumo e incerteza dos dados\n" + summary

    try:
        client = anthropic.Anthropic(api_key=api_key)
        resp = client.messages.create(
            model="claude-opus-4-8",
            max_tokens=16000,
            thinking={"type": "adaptive"},
            system=system,
            messages=convo,
        )
        if resp.stop_reason == "refusal":
            return {"error": "refusal", "message":
                    "O modelo recusou responder a esta solicitacao."}
        text = "".join(b.text for b in resp.content if b.type == "text")
        return {"reply": text}
    except anthropic.AuthenticationError:
        return {"error": "auth", "message":
                "Chave de API invalida. Verifique em Configuracoes."}
    except anthropic.RateLimitError:
        return {"error": "rate", "message":
                "Limite de requisicoes atingido. Tente novamente em instantes."}
    except anthropic.APIStatusError as e:
        return {"error": "api", "message": f"Erro da API ({e.status_code})."}
    except anthropic.APIConnectionError:
        return {"error": "conn", "message":
                "Falha de conexao. Verifique sua internet."}


def _summarize_for_coach(stats: dict) -> str:
    lines = []
    sc = stats.get("scores", {})
    if sc.get("loop_score") is not None:
        lines.append(f"Loop Score de hoje: {sc['loop_score']}/100 ({sc['band']}, "
                     f"confianca {sc.get('confidence')}).")
        for c in sc.get("components", []):
            lines.append(f"  - {c['label']}: {c['score']}/100 ({c['detail']}).")
    if sc.get("strain") is not None:
        lines.append(f"Strain de hoje: {sc['strain']}/21.")
    lines.append(f"Sequencia (streak) de check-ins: {stats.get('streak', 0)} dias.")

    lines.append("\nIncerteza por metrica (cobertura/30d, lacuna, baseline):")
    for p in stats.get("provenance", []):
        lines.append(f"  - {p['label']}: {p['coverage_30d']}/30 dias, "
                     f"lacuna {p['gap_days']}d, baseline={'sim' if p['has_baseline'] else 'nao'}"
                     f" ({p['quality']}).")

    for f, label in (("sleep_hours", "Sono"), ("resting_hr", "FC repouso"),
                     ("hrv", "HRV"), ("spo2", "SpO2")):
        t = stats.get("tiles", {}).get(f, {})
        if t.get("value") is not None:
            d = t.get("delta")
            dtxt = f" (delta7d {d:+.1f})" if d is not None else ""
            lines.append(f"Media 7d {label}: {t['value']:.1f}{dtxt}.")

    recent = stats.get("recent", [])[:14]
    if recent:
        lines.append("\nUltimos dias (mais recente primeiro):")
        for e in recent:
            parts = [e["day"]]
            for f, lbl in (("sleep_hours", "sono"), ("resting_hr", "rhr"),
                           ("hrv", "hrv"), ("workout_minutes", "treino_min"),
                           ("workout_type", "treino"), ("energy", "energia"),
                           ("stress", "estresse"), ("focus", "foco")):
                if e.get(f) is not None:
                    parts.append(f"{lbl}={e[f]}")
            if e.get("notes"):
                parts.append(f'nota="{e["notes"][:80]}"')
            lines.append("  " + ", ".join(parts))
    return "\n".join(lines)


# --------------------------------------------------------------------------
# HTTP handler
# --------------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    server_version = "VwarLoop/1.0"

    def log_message(self, *args):
        pass

    def _send_json(self, obj, status=200):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self) -> dict:
        length = int(self.headers.get("Content-Length", "0") or "0")
        if not length:
            return {}
        try:
            return json.loads(self.rfile.read(length))
        except json.JSONDecodeError:
            return {}

    def _send_file(self, path: Path, content_type: str):
        try:
            data = path.read_bytes()
        except OSError:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        route = urlparse(self.path).path
        if route in ("/", "/index.html"):
            return self._send_file(STATIC_DIR / "index.html", "text/html; charset=utf-8")
        if route == "/manifest.json":
            return self._send_file(STATIC_DIR / "manifest.json", "application/json")
        if route == "/sw.js":
            return self._send_file(STATIC_DIR / "sw.js", "application/javascript")
        if route == "/api/stats":
            return self._send_json(build_stats())
        if route == "/api/entries":
            return self._send_json({"entries": [row_to_entry(r) for r in all_entries()]})
        if route == "/api/settings":
            cfg = load_config()
            return self._send_json({
                "goals": cfg.get("goals", {}),
                "habits": cfg.get("habits", []),
                "has_api_key": bool(cfg.get("anthropic_api_key")
                                    or os.environ.get("ANTHROPIC_API_KEY")),
            })
        if route == "/api/export":
            return self._send_json({
                "exported_at": datetime.now().isoformat(),
                "entries": [row_to_entry(r) for r in all_entries(limit=100000)],
                "settings": {k: v for k, v in load_config().items()
                             if k != "anthropic_api_key"},
            })
        self.send_error(404)

    def do_POST(self):
        route = urlparse(self.path).path
        payload = self._read_json()

        if route == "/api/entries":
            try:
                return self._send_json({"entry": upsert_entry(payload)})
            except (ValueError, KeyError) as e:
                return self._send_json({"error": str(e)}, status=400)

        if route == "/api/settings":
            cfg = load_config()
            if "goals" in payload:
                cfg["goals"] = payload["goals"]
            if "habits" in payload:
                cfg["habits"] = payload["habits"]
            if "anthropic_api_key" in payload:
                key = (payload["anthropic_api_key"] or "").strip()
                if key:
                    cfg["anthropic_api_key"] = key
                else:
                    cfg.pop("anthropic_api_key", None)
            save_config(cfg)
            return self._send_json({"ok": True})

        if route == "/api/coach":
            return self._send_json(run_coach(payload.get("messages", []), build_stats()))

        if route == "/api/import":
            n = 0
            for e in payload.get("entries", []):
                try:
                    upsert_entry(e)
                    n += 1
                except (ValueError, KeyError):
                    continue
            return self._send_json({"imported": n})

        self.send_error(404)


def main():
    init_db()
    httpd = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    url = f"http://localhost:{PORT}"
    print("-" * 60)
    print("  VWAR Loop — seu app pessoal de bem-estar (local-first)")
    print("-" * 60)
    print(f"  Navegador:              {url}")
    print(f"  Celular/iPad (mesma rede):  http://<IP-do-PC>:{PORT}")
    print(f"  Dados guardados em:     {HOME}")
    print("  Ctrl+C para parar.")
    print("-" * 60)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n  Ate logo! Seus dados continuam salvos localmente.")
        httpd.shutdown()


if __name__ == "__main__":
    main()
