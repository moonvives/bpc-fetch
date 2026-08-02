# VWAR Loop

App pessoal de observação de vida para a pulseira **VWAR Loop Life / VWAR MG**.
Local-first: seus dados ficam no seu computador, em `~/.vwarloop`. Sem servidor,
sem conta, sem telemetria. Uso pessoal, não comercial.

Inspirado em [PulseLoop](https://sakshambhutani.xyz/projects/20_project/),
[Goose](https://github.com/b-nnett/goose) e [NOOP](https://github.com/ParthJadhav/noop) —
a mesma ideia de libertar os dados de um wearable barato do app proprietário.

---

## O que ele faz

**Dashboard diário** com Recovery Score (0–100) e Strain, no estilo WHOOP — mas
com a fórmula aberta. Cada componente do score aparece com sua nota, seu peso e
o motivo (`FC 62 bpm vs. base 66`), em vez de um número mágico.

**Painel de qualidade dos dados.** Antes de qualquer conclusão: fonte, cobertura
nos últimos 30 dias, lacuna desde a última medida e se já existe baseline pessoal.
Sinal ruidoso não deve parecer preciso.

**Coach de IA** (opcional) que lê o resumo dos seus 30 dias *e o painel de
incerteza*, e calibra a confiança de cada afirmação. Usa a sua chave da Anthropic,
guardada só no seu computador.

**Respiração coerente** — 4s inspirando, 6s expirando, ~5,5 respirações por
minuto, 5 minutos. A intervenção mais estudada em psicofisiologia para elevar HRV
e restaurar tônus parassimpático.

**Engenharia reversa BLE** (`tools/vwar_ble.py`) para falar direto com a pulseira,
sem o app G Band.

---

## Métricas que este app ignora de propósito

A VWAR anuncia "ácido úrico", "lipídios sanguíneos", "glicose" e "pressão
arterial". O chipset é um **JieLi JL7013A** com sensor óptico (PPG) e eletrodos de
ECG — não existe sensor bioquímico ali. Esses valores são estimativas de software.

A FDA emitiu alerta formal (21/02/2024) contra wearables que afirmam medir
parâmetros sanguíneos sem furar a pele. A própria VWAR declara na ficha técnica
que "este produto não é um dispositivo médico".

Este app não registra, não pontua e não passa esses números para o coach. FC, HRV,
SpO2, sono e passos são tratados como **tendências**, não como medições clínicas.

---

## Instalação

Requer apenas Python 3.10+.

```bash
python3 vwarloop/server.py
```

Abra `http://localhost:8787`.

**No iPhone/iPad:** com o computador e o aparelho na mesma rede, abra
`http://<IP-do-computador>:8787` no Safari e use Compartilhar → Adicionar à Tela
de Início. Vira um app em tela cheia, sem sideload e sem expirar em 7 dias.

**Coach (opcional):**

```bash
pip install anthropic
```

Depois adicione sua chave da Anthropic na aba Dados, ou defina `ANTHROPIC_API_KEY`.

---

## Engenharia reversa do protocolo BLE

`tools/vwar_ble.py` fala direto com a sua pulseira via Bluetooth LE. Requer
`pip install bleak` e um computador com Bluetooth. Não funciona em iOS (o Safari
não expõe Web Bluetooth; no iPhone/iPad isso exigiria um app nativo em
CoreBluetooth).

Importante: desconecte a pulseira do celular antes — o G Band segura a conexão e
impede o computador de conectar.

```bash
# 1. Achar a pulseira
python3 vwarloop/tools/vwar_ble.py scan

# 2. Mapear todos os serviços e características GATT
python3 vwarloop/tools/vwar_ble.py dump --address AA:BB:CC:DD:EE:FF

# 3. Gravar os pacotes crus, com a pulseira no pulso
python3 vwarloop/tools/vwar_ble.py sniff --address AA:BB:CC:DD:EE:FF --seconds 120

# 4. Analisar o log — aponta quais bytes se comportam como FC, bateria, passos
python3 vwarloop/tools/vwar_ble.py analyze ~/.vwarloop/ble/sniff-*.jsonl
```

**O método.** Enquanto grava, anote a hora exata e o que o G Band mostra no mesmo
instante (`22:31 FC=82, bateria=64%`). Esse é o seu gabarito. O subcomando
`analyze` agrupa os pacotes por formato e marca as posições de byte que se
comportam como frequência cardíaca (faixa 40–200), percentual (0–100) ou contador.
Você cruza com o gabarito e acha o campo. Depois confirme com um segundo ponto:
suba a FC com 30 agachamentos, grave de novo e veja se o mesmo byte subiu. Um
acerto é coincidência; dois é o campo.

Se a banda expuser o serviço padrão de Heart Rate (`0x180D`), não há nada a
decodificar — `vwar_ble.py hr` já lê FC e intervalos RR ao vivo, e calcula o
RMSSD (o HRV de verdade, o mesmo que WHOOP e Oura reportam).

Documente o que descobrir em `tools/PROTOCOL.md` e preencha `parse_packet()`.

---

## Alternativa sem BLE: ponte pelo Apple Health

```
VWAR Loop Life → G Band → Saúde da Apple → exportação → este app
```

No G Band, ative a integração com a Saúde da Apple. Exporte os dados pelo app
Saúde (Perfil → Exportar Todos os Dados) e importe o JSON na aba Dados. A glicose
escrita pelo G Band é descartada na importação pelo motivo descrito acima.

---

## Como o Recovery Score é calculado

Média ponderada, renormalizada quando faltam campos — um dia incompleto não zera
o score.

| Componente | Peso | Regra |
|---|---|---|
| Sono | 0,30 | horas ÷ meta |
| FC de repouso | 0,25 | z-score contra sua baseline de 30 dias, invertido |
| HRV | 0,25 | z-score contra sua baseline de 30 dias |
| Subjetivo | 0,20 | energia, estresse, dor, qualidade do sono |

A baseline é sua, não populacional. Por isso os primeiros 14 dias servem para
calibrar — o painel de qualidade mostra quando cada métrica passa a ter baseline
confiável.

---

## Aviso

Dispositivo e app de bem-estar, não médico. Nada aqui diagnostica, trata ou
substitui avaliação profissional. Para pressão arterial use um aparelho de braço
validado pelo Inmetro; para ácido úrico, lipídios e glicose, exames laboratoriais.
