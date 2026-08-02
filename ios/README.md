# VWAR Loop — app iOS

App nativo em SwiftUI para iPhone e iPad. Substitui o G Band para leitura e
análise: os dados ficam num store local no aparelho, sem servidor, sem conta e
sem telemetria.

Requer iOS 17 ou superior.

---

## Como conseguir o IPA

**Link mais recente, abrível no Safari do próprio iPhone/iPad:**
https://github.com/moonvives/bpc-fetch/releases

Abra o release mais novo e toque em `VwarLoop-unsigned.ipa`. O download vai
direto para Arquivos, de onde o AltStore/SideStore consegue abri-lo.


A cada push que toca `ios/`, o workflow **Build iOS IPA (unsigned)** compila num
runner macOS do GitHub Actions e publica o arquivo.

**Artefato do workflow:** aba Actions → a execução mais recente → seção
Artifacts → `VwarLoop-unsigned-ipa`. Fica disponível por 90 dias.

**Release:** aba Actions → Build iOS IPA (unsigned) → Run workflow → marque
"Publicar também como release". O IPA aparece em Releases.

Nenhuma credencial da Apple é usada ou armazenada no repositório. O IPA sai
**sem assinatura** — é você quem assina, com o seu próprio Apple ID.

---

## Instalação — leia isto antes

**O Modo de Desenvolvedor do iOS não instala IPAs não assinados.** Ele libera a
*execução* de apps já assinados com certificado de desenvolvimento. Um IPA sem
assinatura precisa ser assinado por alguém antes de instalar: pelo Xcode com o
seu Apple ID, ou por AltStore/SideStore, que assinam com o seu Apple ID no
aparelho.

### Opção 1 — Xcode (recomendado)

É o único caminho que preserva o entitlement do HealthKit. Sem ele, o app não
aparece na Saúde da Apple e não recebe nada do G Band.

```bash
brew install xcodegen
cd ios
```

Em `project.yml`, troque dois valores:

- `PRODUCT_BUNDLE_IDENTIFIER` para um identificador que você controla, por
  exemplo `com.seunome.vwarloop`
- `DEVELOPMENT_TEAM` para o seu Team ID (Xcode → Settings → Accounts → sua conta
  → Manage Certificates; o Team ID aparece no painel da conta)

Depois:

```bash
xcodegen generate
open VwarLoop.xcodeproj
```

No Xcode, escolha o iPhone ou iPad conectado, selecione o scheme `VwarLoop` e
rode. Na primeira execução o iOS pede para confiar no certificado:
Ajustes → Geral → VPN e Gerenciamento de Dispositivo → confie no seu Apple ID.
Em iOS 16+ também é preciso ativar Ajustes → Privacidade e Segurança → Modo de
Desenvolvedor.

### Opção 2 — AltStore ou SideStore

Baixe o IPA do Actions ou dos Releases e abra no AltStore/SideStore. Eles assinam
com o seu Apple ID e instalam.

Com Apple ID gratuito o app expira em 7 dias e precisa ser renovado — deixe o
AltStore/SideStore instalado para renovar sozinho. Além disso, a re-assinatura
por serviços genéricos costuma perder o entitlement do HealthKit; se isso
acontecer, o app não aparece na Saúde e a ponte com o G Band não funciona. O
resto (Bluetooth, check-in, scores, coach) continua funcionando.

Não entregue suas credenciais da Apple nem exportações de saúde para serviços de
assinatura de terceiros.

---

## Dados: dois caminhos

### Saúde da Apple (funciona no primeiro dia)

```
VWAR Loop Life → G Band → Saúde da Apple → VWAR Loop
```

No G Band, ative a integração com a Saúde e permita frequência cardíaca,
distância, energia, oxigenação, passos, sono e temperatura. No app, aba Dados →
Autorizar leitura da Saúde → Sincronizar.

A glicose escrita pelo G Band **não é importada**. É uma estimativa óptica sem
validação clínica. Pressão arterial e ECG também não entram como medição.

### Bluetooth direto

Aba Check-in → Pulseira → Conectar. Desconecte a pulseira do G Band antes: uma
banda BLE aceita uma conexão central por vez.

Se a pulseira expuser o serviço padrão de frequência cardíaca (`0x180D`), o app
lê batimentos e intervalos RR ao vivo e calcula **RMSSD de verdade** — o mesmo
cálculo que WHOOP e Oura reportam como HRV, com filtro de artefatos, em vez de um
número pronto de caixa-preta.

Se ela só falar o protocolo proprietário da JieLi, os pacotes brutos são gravados
e aparecem na aba Dados, exportáveis no mesmo formato que
`../vwarloop/tools/vwar_ble.py analyze` consome.

---

## O que o app se recusa a fazer

A VWAR anuncia ácido úrico, lipídios, glicose e pressão arterial. O chipset é um
JieLi JL7013A com sensor óptico e eletrodos de ECG — não existe sensor
bioquímico. Esses valores são saída de algoritmo, não leitura de analito. A FDA
alertou formalmente sobre isso em 21/02/2024, e a própria VWAR declara na ficha
técnica que o produto não é dispositivo médico.

Esses números ficam fora de todo score, de toda tendência e do prompt do coach.

---

## Estrutura

```
ios/
  project.yml                  spec do XcodeGen
  VwarLoop/
    VwarLoopApp.swift          entrada, container SwiftData
    Theme.swift                paleta e componentes
    Models/
      DailyEntry.swift         modelo do dia + backup JSON
      ScoreEngine.swift        Recovery, Strain, baselines, tendências
      Provenance.swift         painel de incerteza
    Health/HealthKitBridge.swift
    BLE/BandManager.swift      CoreBluetooth + RMSSD
    Coach/CoachClient.swift    Anthropic + Keychain
    Views/                     Hoje, Check-in, Coach, Dados
```

O formato de backup é o mesmo do web app em `../vwarloop`, então dá para migrar
nos dois sentidos.

---

## Aviso

App de bem-estar, não dispositivo médico. Não diagnostica, não trata e não
substitui avaliação profissional. O coach é instruído a não orientar sobre
medicação. Para pressão arterial, aparelho de braço validado pelo Inmetro; para
ácido úrico, lipídios e glicose, exame laboratorial.
