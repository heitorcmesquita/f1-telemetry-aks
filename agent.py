"""
F1 Race Commentary Agent — Google Gemini + Azure SQL
------------------------------------------------------
Dois modos de uso:
  1. Teste:     python agent.py
  2. Proativo:  python agent.py proativo

Requerimentos:
    pip install groq pyodbc schedule

Variáveis de ambiente necessárias:
    GROQ_API_KEY    — chave da API do Groq (console.groq.com)
    SQL_SERVER      — só o prefixo, ex: openf1-sqlserver-brazilsouth
    SQL_PASSWORD    — senha do admin
"""

import os
import json
import time
import schedule
import threading
import pyodbc
from groq import Groq
from datetime import datetime

# ── Configuração ────────────────────────────────────────────────────────────

client = Groq(api_key=os.environ["GROQ_API_KEY"])

def _conectar():
    server   = f"{os.environ['SQL_SERVER']}.database.windows.net"
    user     = os.environ.get("SQL_USER", "openf1admin")
    password = os.environ["SQL_PASSWORD"]
    base = f"Server={server};Database=f1db;UID={user};PWD={password};Encrypt=yes;TrustServerCertificate=no;"
    for driver in ["ODBC Driver 18 for SQL Server", "ODBC Driver 17 for SQL Server", "ODBC Driver 13 for SQL Server"]:
        try:
            c = pyodbc.connect(f"Driver={{{driver}}};" + base)
            print(f"  ✅ Conectado via [{driver}]")
            return c
        except Exception:
            continue
    raise RuntimeError("Nenhum ODBC Driver encontrado. Baixe em: https://aka.ms/downloadmsodbcsql")

conn = _conectar()

# ── Funções que acessam o Azure SQL ─────────────────────────────────────────

def consultar_posicoes(session_key: str, limit: int = 50) -> list:
    cursor = conn.cursor()
    cursor.execute(f"""
        SELECT TOP {int(limit)} driver_number, position, date
        FROM positions
        WHERE session_key = ?
        ORDER BY processed_at DESC
    """, (int(session_key),))
    return [dict(zip([c[0] for c in cursor.description], row)) for row in cursor.fetchall()]


def consultar_voltas(session_key: str, limit: int = 30) -> list:
    cursor = conn.cursor()
    cursor.execute(f"""
        SELECT TOP {int(limit)} driver_number, lap_number, lap_duration, date_start
        FROM laps
        WHERE session_key = ?
        ORDER BY processed_at DESC
    """, (int(session_key),))
    return [dict(zip([c[0] for c in cursor.description], row)) for row in cursor.fetchall()]


def consultar_telemetria(session_key: str, driver_number: int) -> list:
    cursor = conn.cursor()
    cursor.execute("""
        SELECT TOP 20 speed, rpm, throttle, brake, date
        FROM telemetry
        WHERE session_key = ? AND driver_number = ?
        ORDER BY processed_at DESC
    """, (int(session_key), int(driver_number)))
    return [dict(zip([c[0] for c in cursor.description], row)) for row in cursor.fetchall()]


def consultar_clima(session_key: str) -> list:
    cursor = conn.cursor()
    cursor.execute("""
        SELECT TOP 5 air_temperature, humidity, rainfall, wind_speed, date
        FROM weather
        WHERE session_key = ?
        ORDER BY processed_at DESC
    """, (int(session_key),))
    return [dict(zip([c[0] for c in cursor.description], row)) for row in cursor.fetchall()]


FERRAMENTAS_FN = {
    "consultar_posicoes":   consultar_posicoes,
    "consultar_voltas":     consultar_voltas,
    "consultar_telemetria": consultar_telemetria,
    "consultar_clima":      consultar_clima,
}

# ── Definição das ferramentas para o Gemini ─────────────────────────────────

TOOLS_GROQ = [
    {
        "type": "function",
        "function": {
            "name": "consultar_posicoes",
            "description": "Retorna posições atuais dos pilotos na corrida",
            "parameters": {
                "type": "object",
                "properties": {
                    "session_key": {"type": "string"},
                    "limit":       {"type": "integer"},
                },
                "required": ["session_key"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "consultar_voltas",
            "description": "Retorna tempos de volta. Use para detectar degradação ou ritmo.",
            "parameters": {
                "type": "object",
                "properties": {
                    "session_key": {"type": "string"},
                    "limit":       {"type": "integer"},
                },
                "required": ["session_key"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "consultar_telemetria",
            "description": "Retorna telemetria de um piloto: velocidade, RPM, throttle, brake",
            "parameters": {
                "type": "object",
                "properties": {
                    "session_key":   {"type": "string"},
                    "driver_number": {"type": "integer"},
                },
                "required": ["session_key", "driver_number"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "consultar_clima",
            "description": "Retorna condições climáticas da pista",
            "parameters": {
                "type": "object",
                "properties": {
                    "session_key": {"type": "string"},
                },
                "required": ["session_key"]
            }
        }
    },
]

# ── Loop interno do agente ───────────────────────────────────────────────────

def _executar_agente(system: str, mensagem: str, verbose: bool = True) -> str:
    messages = [
        {"role": "system", "content": system},
        {"role": "user",   "content": mensagem},
    ]

    for _ in range(8):
        response = client.chat.completions.create(
            model="llama-3.3-70b-versatile",
            messages=messages,
            tools=TOOLS_GROQ,
            tool_choice="auto",
        )

        msg = response.choices[0].message

        # Sem tool call — resposta final
        if not msg.tool_calls:
            return msg.content

        # Executa todas as tool calls retornadas
        messages.append(msg)
        for tc in msg.tool_calls:
            nome   = tc.function.name
            params = json.loads(tc.function.arguments)

            if verbose:
                print(f"  🔧 [{nome}] params={params}")

            try:
                resultado = FERRAMENTAS_FN[nome](**params)
            except Exception as e:
                resultado = {"erro": str(e)}

            messages.append({
                "role":         "tool",
                "tool_call_id": tc.id,
                "content":      json.dumps(resultado, default=str),
            })

    return response.choices[0].message.content

# ── Modo 1: Interativo ───────────────────────────────────────────────────────

def agente_f1(pergunta: str, session_key: str, verbose: bool = True) -> str:
    system = (
        "Você é um comentarista técnico de F1 experiente e apaixonado. "
        "Sempre consulte os dados disponíveis antes de responder. "
        "Forneça análises técnicas detalhadas mas acessíveis. "
        "Quando relevante, mencione estratégias de pit stop, degradação de pneus e clima."
    )
    return _executar_agente(system, f"Session key: {session_key}\n\nPergunta: {pergunta}", verbose)

# ── Modo 2: Proativo ─────────────────────────────────────────────────────────

_estado_anterior = {}

def _ciclo_proativo(session_key: str, callback=None):
    global _estado_anterior

    system = (
        "Você é um agente de monitoramento de corrida F1. "
        "Consulte os dados disponíveis e decida SE há algo relevante para comentar. "
        "Só comente quando detectar: mudança de posição, pit stop, degradação de pneu "
        "acelerada, mudança climática, ou ritmo muito diferente entre pilotos. "
        "Se nada relevante estiver acontecendo, responda EXATAMENTE com: NADA_RELEVANTE. "
        "Quando comentar, seja direto, técnico e empolgante — máximo 3 parágrafos."
    )

    estado_str = json.dumps(_estado_anterior, default=str)
    mensagem = (
        f"Session key: {session_key}\n"
        f"Estado anterior: {estado_str}\n\n"
        "Consulte os dados atuais. Houve algo relevante desde o último ciclo?"
    )

    resposta = _executar_agente(system, mensagem, verbose=True)

    if "NADA_RELEVANTE" in resposta:
        print(f"  [{_hora()}] — sem novidades")
        return

    try:
        posicoes = consultar_posicoes(session_key, limit=20)
        _estado_anterior = {"posicoes": posicoes}
    except Exception:
        pass

    timestamp = _hora()
    print(f"\n🎙️  [{timestamp}]\n{resposta}\n{'─'*60}")

    if callback:
        callback(timestamp=timestamp, comentario=resposta)


def _hora() -> str:
    return datetime.now().strftime("%H:%M:%S")


def iniciar_modo_proativo(session_key: str, intervalo_segundos: int = 30, callback=None, bloqueante: bool = True):
    print(f"🏎️  Agente F1 proativo iniciado — verificando a cada {intervalo_segundos}s")
    print(f"   Session: {session_key} | Pressione Ctrl+C para parar\n{'═'*60}\n")

    schedule.every(intervalo_segundos).seconds.do(_ciclo_proativo, session_key=session_key, callback=callback)
    _ciclo_proativo(session_key, callback)

    if bloqueante:
        try:
            while True:
                schedule.run_pending()
                time.sleep(1)
        except KeyboardInterrupt:
            print("\n🏁 Agente encerrado.")
            schedule.clear()
    else:
        def _loop():
            while True:
                schedule.run_pending()
                time.sleep(1)
        threading.Thread(target=_loop, daemon=True).start()

# ── Diagnóstico e auto-descoberta ────────────────────────────────────────────

def descobrir_sessao():
    cursor = conn.cursor()
    for tabela in ["positions", "laps", "weather"]:
        try:
            cursor.execute(f"SELECT TOP 1 session_key FROM {tabela} ORDER BY processed_at DESC")
            row = cursor.fetchone()
            if row and row[0]:
                print(f"  ✅ Session encontrada em [{tabela}]: {row[0]}")
                return str(row[0])
        except Exception as e:
            print(f"  ⚠️  {tabela}: {e}")
            continue
    return None


def diagnostico():
    cursor = conn.cursor()
    print("\n📊 DIAGNÓSTICO DO BANCO\n" + "─" * 40)
    tabelas = {
        "positions": "Posições",
        "laps":      "Voltas",
        "telemetry": "Telemetria",
        "weather":   "Clima",
    }
    for tabela, nome in tabelas.items():
        try:
            cursor.execute(f"SELECT COUNT(*) FROM {tabela}")
            count = cursor.fetchone()[0]
            print(f"  {nome:12} → {count:>6} registros")
        except Exception as e:
            print(f"  {nome:12} → ERRO: {e}")
    print("─" * 40 + "\n")

# ── Execução principal ───────────────────────────────────────────────────────

if __name__ == "__main__":
    import sys
    modo = sys.argv[1] if len(sys.argv) > 1 else "teste"

    print("🏎️  F1 Agent\n")

    diagnostico()
    SESSION_KEY = descobrir_sessao()

    if not SESSION_KEY:
        print("❌ Nenhuma sessão encontrada no banco. O pipeline está rodando?")
        exit(1)

    if modo == "proativo":
        iniciar_modo_proativo(SESSION_KEY, intervalo_segundos=30)
    else:
        print(f"\n🔍 Analisando sessão: {SESSION_KEY}\n" + "═" * 60)
        perguntas = [
            "Analise as posições. Quem aparece nos dados? Como estão os gaps?",
            "Analise os tempos de volta. Há degradação ou melhora de ritmo?",
            "Como está o clima? Isso influencia a estratégia?",
            "Faça um resumo geral da sessão com base em tudo que você viu.",
        ]
        for pergunta in perguntas:
            print(f"\n🎙️  {pergunta}\n")
            print(agente_f1(pergunta, SESSION_KEY))
            print("─" * 60)