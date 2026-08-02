# VWAR Loop — aplicativo iOS

Sistema pessoal de saúde, treinamento e hábitos para iPhone e iPad. Processamento
local: os dados ficam no aparelho, sem servidor, sem conta e sem telemetria.

Requer iOS 17 ou superior.

---

## Como conseguir o arquivo de instalação

**Link mais recente, abrível no Safari do próprio aparelho:**
https://github.com/moonvives/bpc-fetch/releases

Abra o release mais novo e toque em `VwarLoop-unsigned.ipa`. O download vai para
Arquivos, de onde o assinador consegue abri-lo.

Também sai como artefato em cada execução do fluxo **Build iOS IPA (unsigned)**
na aba Actions, com retenção de 90 dias.

Nenhuma credencial da Apple é usada ou guardada no repositório.

---

## Instalação

O arquivo sai **sem assinatura**. O Modo de Desenvolvedor do iOS não instala
binários sem assinatura — ele libera a execução de aplicativos já assinados com
certificado de desenvolvimento. Alguém precisa assinar antes: o Xcode com o seu
Apple ID, ou um assinador local.

### Compilar no Xcode

É o único caminho que preserva a permissão de Saúde. Sem ela, o aplicativo não
aparece na Saúde e não recebe sono, atividade nem as leituras de pressão.

```bash
brew install xcodegen
cd ios
```

Em `project.yml`, troque `PRODUCT_BUNDLE_IDENTIFIER` por um identificador que
você controla e `DEVELOPMENT_TEAM` pelo seu Team ID (Xcode → Settings →
Accounts). Depois:

```bash
xcodegen generate
open VwarLoop.xcodeproj
```

Selecione o aparelho, o esquema `VwarLoop` e execute. Na primeira execução, o iOS
pede para confiar no certificado em Ajustes → Geral → VPN e Gerenciamento de
Dispositivo, e o Modo de Desenvolvedor precisa estar ativo em Ajustes →
Privacidade e Segurança.

### Assinador local

Baixe o arquivo do release e abra no assinador de sua preferência, que o assina
com o seu Apple ID e instala. Com Apple ID gratuito o aplicativo expira em sete
dias e precisa ser renovado; mantenha o assinador instalado para renovar sozinho.

A reassinatura por serviços genéricos costuma remover a permissão de Saúde. Nesse
caso o aplicativo avisa na área **Qualidade dos dados** e todo o resto continua
funcionando com registro manual. Não entregue credenciais da Apple nem
exportações de saúde a serviços de assinatura de terceiros.

---

## Fontes de dados

| Fonte | O que chega |
|---|---|
| Saúde da Apple | frequência cardíaca, FC de repouso, variabilidade, frequência respiratória, temperatura cutânea, sono com estágios, passos, distância, gasto ativo, exercícios, VO₂ máximo, peso, composição corporal, cafeína e álcool quando registrados |
| Strava | tipo, duração, distância, elevação e frequência cardíaca das sessões, através da integração com a Saúde |
| Aparelho de pressão | sistólica, diastólica, pulso, data e hora, importados pela Saúde e marcados como medida de manguito |

Leituras de pressão cuja origem não é um aparelho de braço ficam registradas, mas
fora da série padronizada usada para tendência.

---

## Áreas

**Hoje** — três eixos: recuperação e sono, carga e movimento, pressão e saúde
cardiovascular. Cada um mostra a comparação com a própria mediana recente e a
disponibilidade de dados. Abaixo, o que mudou e os registros de contexto do dia.

**Recuperação** — abre as três camadas em vez de resumi-las: sinal fisiológico,
sono e carga recente. A leitura diz se a recuperação está abaixo, próxima ou
acima da faixa recente, nomeia as métricas que contribuíram e as que faltaram.

**Treino** — carga por semana, distribuição de intensidade sem rotular faixas
como boas ou ruins, capacidade aeróbica com a ressalva de variabilidade das
estimativas, força e sessões recentes.

**Saúde** — pressão arterial, sono, exames, qualidade dos dados e quando procurar
ajuda.

**Diário** — álcool, cafeína, medicação, sintomas, dor, estresse percebido,
refeições tardias, doença e observação livre.

---

## Pressão arterial

A área tem protocolo próprio porque uma medida de manguito é uma classe de
evidência diferente de uma estimativa óptica.

**Medição matinal de referência.** Três medidas pela manhã, antes de comer,
treinar ou usar estimulantes, com cinco minutos de repouso antes da primeira e um
minuto entre elas. O aplicativo conduz as etapas, cronometra as esperas, registra
cada medida separadamente, calcula a média e guarda a aderência ao protocolo.
Contexto opcional: sono, álcool no dia anterior, treino intenso, cafeína precoce,
estresse percebido, doença, dor e medicação.

**Leitura noturna contextual.** Acompanha como o dia se refletiu na pressão. Não
substitui a média matinal padronizada para tendência.

A tela mostra a última medida válida, tendências de 7, 30 e 90 dias com sistólica
e diastólica em séries separadas, médias matinal e noturna, o percentual de
sessões com protocolo completo, a distribuição das leituras e a tabela recente
com data, hora, valores, pulso, origem e observações.

O aplicativo não orienta ajuste de medicação, sal, eletrólitos ou dieta.

---

## Qualidade dos dados

Cada métrica mostra fonte, número de observações, cobertura no período, data da
última leitura, duplicações, maior lacuna, se a medida é direta ou derivada, e o
grau de confiança com a justificativa.

Sem base suficiente, a tela diz que ainda não há dados para uma tendência
confiável, em vez de interpretar série fina.

**Excluídas da interpretação:** glicose, lipídios, ácido úrico e pressão arterial
estimados por sensor óptico de pulso. São estimativas sem validação para decisão
clínica e não entram em tendência, indicador ou recomendação. Para esses
marcadores, exame laboratorial; para pressão, aparelho de braço.

---

## Insights

Formato fixo, sempre com as cinco seções visíveis: dado observado, comparação, o
que pode estar relacionado, limitações e próximo passo. Um insight só é gerado
quando existe métrica válida, janela clara, baseline suficiente e confiança
declarada. Registros de contexto aparecem como associação, nunca como causa.

---

## Acessibilidade

Dynamic Type em toda a interface, contraste alto nas duas aparências, VoiceOver
com rótulo e valor em cada leitura, gráficos acompanhados de tabela equivalente,
cor nunca como único portador de significado, alvos de toque amplos e layout em
duas colunas no iPad.

---

## Estrutura

```
ios/VwarLoop/
  App.swift                    entrada, navegação, consultas compartilhadas
  Design/
    Palette.swift              cores, formatação
    Components.swift           painéis, tendências, gráficos, insights
  Models/
    Core.swift                 perfil, observações, sono, exercício
    BloodPressure.swift        leituras, sessões, protocolo
    LabsAndContext.swift       exames, diário, medicação, sintomas
  Analysis/
    Trend.swift                baseline pessoal, janelas, confiança
    DataQuality.swift          cobertura, lacunas, métricas excluídas
    Insights.swift             formato fixo, avisos de segurança
  Sources/
    AppleHealthSource.swift    importação e trilha de auditoria
  Views/
    TodayView.swift
    RecoveryAndTraining.swift
    BloodPressureViews.swift
    HealthAndJournal.swift
```

---

## Aviso

Aplicativo de bem-estar, não dispositivo médico. Não diagnostica, não trata e não
substitui avaliação profissional. Sintomas importantes pedem avaliação médica
independentemente de qualquer indicador do aplicativo.
