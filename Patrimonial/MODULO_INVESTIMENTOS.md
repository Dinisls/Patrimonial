# Módulo de Investimentos

Cotações, carteira, alocação, watchlist, evolução e gráficos. Este documento
descreve como o módulo está construído e, sobretudo, **porque** é que está
construído assim: quase todas as decisões abaixo existem porque a alternativa
óbvia já esteve no código e produziu um número errado no telemóvel.

A regra que atravessa tudo: **um valor que não se sabe mostra-se como travessão
e fica fora dos totais.** Nunca 0, nunca 1, nunca o último valor conhecido sem
dizer que o é. Um número errado que passou por uma validação é pior do que um
número errado, porque deixou de parecer um.

---

## 1. Camadas

```
Providers  →  PriceStore  →  PortfolioCalculator  →  ViewModel  →  View
(rede)        (verdade em     (matemática pura)      (estado)     (só desenha)
              memória)
```

- **Providers** falam com a rede e devolvem `Quote`. Não sabem o que é uma
  carteira.
- **PriceStore** é a única fonte de verdade para preços. Faz o routing por
  praça, aplica os guards de identidade, publica em `quotes`, persiste em
  `PriceSnapshot` e trata do polling.
- **PortfolioCalculator** é uma `struct` pura: sem I/O, sem SwiftData, sem
  `PriceStore` lá dentro. Recebe transações, devolve `Holding`.
- **ViewModel** junta os dois e expõe propriedades prontas a desenhar.
- **View** não tem lógica financeira nenhuma. Zero.

Toda a aritmética de dinheiro é em `Decimal`. `Double` não entra em nada que
represente dinheiro — e `Decimal(algumDouble)` também não, porque escreve
`1234,5599999999997952`; a conversão passa pela string decimal
(`AppStore.money(from:)`).

---

## 2. Identidade: uma posição é uma **listagem**, não um ticker

`ListingID(symbol:mic:)` é a chave de tudo — transações, `PriceStore.quotes`,
`PriceSnapshot`, `CandleCache`, `Asset`.

**Porquê:** `NVD` é a NVIDIA nas praças alemãs (XETR/XFRA/XSTU/XMUN, EUR) **e**
o GraniteShares 2x Short Nvidia ETF no NASDAQ (XNMS, USD). Com o dicionário
`quotes["NVD"]` havia espaço para um preço e dois instrumentos a quererem-no:
ganhava quem respondesse por último. O resultado no ecrã foi uma posição a
3,97 EUR com preço médio de 194,22 EUR e −97,96 %.

Consequências dessa escolha:

- `XNGS`, `XNMS`, `XNCM` são grafias, não praças. `MarketCalendar.venuesAgree`
  compara **praças**, não strings — uma chave que admite três grafias são três
  posições onde o utilizador tem uma.
- A migração fez backfill **inequívoco**: só atribui praça a movimentos antigos
  quando existe exatamente uma praça possível para aquele ticker.
- O guard `AssetConflictError.unattributedRows` **mudou de sentido**. Antes
  recusava registar o mesmo ticker em duas praças. Agora a app aguenta as duas
  — é isso o ponto F — e o guard só dispara no único caso em que aceitar
  destrói informação: existem movimentos sem praça gravada, hoje atribuíveis
  porque só há uma praça em jogo, e admitir a segunda torná-los-ia
  inatribuíveis para sempre, partindo o preço médio em dois sem explicação.
  Passou de "impedir o segundo" para "proteger o primeiro".

---

## 3. Providers e routing

Ordem, por praça:

| Ordem | Provider | Cobre | Natureza do preço |
|---|---|---|---|
| 1 | Twelve Data | ações EUA | intradiário |
| 2 | Finnhub | ações EUA (fallback) | intradiário |
| — | CoinGecko | cripto | intradiário |
| 3 | Alpha Vantage | praças europeias | **fecho diário** |
| 4 | Yahoo (não oficial) | o resto (XFRA, XMUN, XDUS, XBUE, XMEX, XTSE, XBOG…) | **fecho diário** |

Limites verificados em direto, não lidos na documentação:

- Twelve Data grátis: 800 créditos/dia, 8 pedidos/min, e **`mic_code` é plano
  pago** (`?symbol=NVD&mic_code=XETR` devolve 404). Mandar a praça na pergunta
  não é opção — daí a correção ser *recusar a resposta*, não afinar a pergunta.
- Finnhub `/stock/candle` é premium; `/quote` devolve **403** para não-EUA.
- Alpha Vantage grátis: 25 pedidos/dia, `outputsize=full` é premium. Os
  contadores vivem em `UserDefaults`, não em memória — um balde em memória
  reinicia a cada arranque e passava dos 25 à hora de almoço. Reserva de 5
  pedidos para o histórico, para os preços não esgotarem o gráfico.
- Sufixos confirmados: `GALP.LS` ✅, `EDP.LS` ✅, `IWDA.AS` ✅; `GALP.LI` ❌ e
  `ELI:GALP` ❌ dão "Invalid API call".

### Decisão: Lima (XLIM) fica de fora

O sufixo `.LM` do Yahoo *responde*. Responde com moeda a null, `exchange` a
"YHD" (o placeholder do Yahoo, não Lima) e um `regularMarketTime` de 2019. É um
endpoint morto a usar um sufixo. Mapeá-lo publicaria um preço para uma praça que
ninguém está a cotar — e um preço de 2019 no ecrã não se distingue de um preço
de hoje. Ausência é a resposta correta.

### Decisão: o `previousClose` vem da série, não do `meta`

O `chartPreviousClose` do Yahoo é o fecho anterior ao **início do intervalo do
gráfico**, portanto o mesmo campo para o mesmo instrumento muda com o intervalo:
QDVE.F reporta 20,105 em `range=1d` e 42,69 em `range=5d`. Nenhum dos dois é
"ontem" no sentido de que uma variação diária precisa. O fecho anterior honesto
é a última barra de uma sessão anterior àquela a que o preço publicado pertence,
e é isso que `closeBeforeSession(of:)` procura. O `meta` fica como recurso para
o caso de uma só barra (Munique devolve um único ponto mesmo com `range=5d`).

---

## 4. Os guards de identidade, por ordem

A ordem é a substância, não um detalhe de implementação.

1. **`mayAskUSProviders`** — se a praça gravada não é americana, os providers
   americanos nem chegam a ser perguntados. Filtrar a resposta depois funciona
   para o Twelve Data, que reporta o MIC, mas não para o Finnhub, que não
   reporta nada — e o Finnhub devolve o mesmo 3,97.
2. **`answersAboutRecordedListing`** — uma resposta cujo MIC contradiz o
   gravado não é um preço velho nem um preço mau: é **outro instrumento**. Não
   se publica, não conta como cobertura, e não impede os providers roteados por
   praça de serem tentados.
3. **`currencyAgreesWithRecordedListing`** — o mesmo raciocínio, mais grosseiro,
   para as listagens sem MIC gravado (posições anteriores ao ponto F). EUR e USD
   não podem estar ambos certos sobre a mesma listagem. Silêncio não é
   contradição: um provider que não reporta moeda não desencadeia recusa.
4. **`rekeyed`** — só aqui é que a moeda gravada é imposta ao preço.

### Decisão: a moeda gravada só pode ser imposta **depois** da praça confirmada

Invertida, esta ordem não é uma proteção, é um **amplificador**. Foi exatamente
o que transformou 3,97 USD em 3,97 EUR: deu ao preço de um instrumento
estrangeiro o rótulo em euros de uma listagem de onde ele nunca veio, e com ele
um câmbio de 1 e um −97,96 % com ar de facto verificado.

A moeda gravada existe para proteger — o Finnhub carimbava tudo com USD e um ETF
cotado em euros levava com um câmbio USD→EUR — mas só é a autoridade **sobre um
preço cuja praça já foi confirmada**. Sem essa confirmação, a divergência de
moeda é prova de que a resposta é sobre outra coisa, e a posição fica com
travessão.

### Decisão: a taxa de câmbio é um tipo com direção, não um `Decimal`

`FXRate(from:to:value:)`, e a conversão é feita **pela taxa**:
`rate.convert(amount, from: currency)` devolve `nil` se a moeda do dinheiro não
for a moeda de onde a taxa converte.

**Porquê:** 0,8669 e 1,1535 são ambos câmbios USD/EUR plausíveis e um `Decimal`
solto não distingue um do outro. Todas as falhas de moeda deste módulo foram
falhas de *direção*, e de cada vez o número tinha um aspeto perfeitamente
razoável.

O Swift **não** consegue tornar a inversão um erro de compilação: as moedas
chegam como strings dos providers, portanto não podem ser tipos estáticos, e
tipos-fantasma sobre um enum apenas mudariam o palpite para o sítio onde a
string vira caso. O que este tipo faz é tornar uma taxa invertida **inutilizável**:
a conversão recusa-se a correr e a posição mostra travessão, em vez de mostrar um
número 33 % errado. É a mesma troca que o módulo faz em todo o lado — uma
ausência visível em vez de um erro invisível.

Onde não se aplica: `FinancialTransaction.assetFXRate`, a taxa **histórica** da
compra, continua um `Decimal` persistido em SwiftData. Mudar-lhe o tipo era uma
migração de esquema por um ganho que a taxa viva já cobre.

### Decisão: `.closed` e `.dailyClose` distinguem-se pela forma, não só pela cor

Círculo cheio para uma cotação viva (verde, laranja, vermelho conforme a idade),
círculo **vazado** para mercado fechado, **quadrado** cheio para fecho de sessão.
Os dois cinzentos eram o mesmo ponto e não são a mesma afirmação: um diz *a
bolsa está fechada*, o outro diz *esta é a melhor cotação que existe, e a bolsa
até pode estar aberta agora*. Uma posição XETRA às 16:00 de Berlim, com o XETRA a
negociar, mostrava cinzento — e cinzento foi lido, com razão, como "fechado".

Cor sozinha também falharia para cerca de 8 % dos homens. `FreshnessLegend`
explica os cinco estados por palavras e está acessível dos três ecrãs que
desenham pontos: carteira, watchlist e detalhe.

### Camada 2: plausibilidade contra o próprio histórico

`PriceStore.referenceClose` (closure injetado, ligado à última vela do
`CandleStore`) mais `isPlausible` no `applyQuote`: acima de 10× em qualquer
direção a cotação é recusada, grava-se uma `Discrepancy` e a `revision` sobe.
Um split superior a 10:1 na janela antes do refresh das velas é recusado — um
travessão que se cura sozinho, que é o lado certo do erro.

---

## 5. Seletor de período — "Hoje" generalizado para sete intervalos

O cabeçalho dizia "Hoje +5,46 €" ao lado de um P/L de +0,00 €. Ambos os números
estavam aritmeticamente certos e descreviam **períodos de detenção diferentes**:
o P/L mede desde o custo, a variação diária desde o fecho anterior — que era
anterior à compra.

**Regra 1 — por lote, não por posição.** Cada lote aberto na sessão mede-se a
partir de `max(fecho anterior, preço de compra do lote)`. Por lote porque duas
compras no mesmo dia, uma de cada lado do fecho anterior, precisam de referências
próprias; e uma compra de hoje não pode contaminar as ações antigas. O `max` é a
metade conservadora: um lote comprado *abaixo* do fecho anterior realmente ganhou
mais do que o instrumento, e a app reporta só o movimento do instrumento —
subestima em vez de reclamar um ganho que a sessão não produziu.

**Regra 2 — o dia de calendário não é uma sessão.** Ao sábado a cotação é o fecho
de sexta e o fecho anterior é o de quinta. Com `startOfDay(now)`, a compra de
sexta caía *fora* da sessão, era tratada como posição antiga e recebia o
movimento quinta→sexta que não viveu. `MarketCalendar.currentSessionStart` recua
até ao último dia em que a praça negoceia e cujo sino já tocou.

**Regra 3 — uma sessão tem duas pontas.** As duas regras acima não cobrem o preço
de fecho diário. Segunda-feira às 15:00 o XETRA está aberto, o relógio diz que a
sessão começou às 00:00 de segunda, e o preço disponível continua a ser o fecho
de sexta porque nenhuma fonte gratuita tem melhor. Uma compra feita às 14:00 de
segunda cai dentro da sessão do relógio e é medida contra o fecho de quinta —
duas sessões que não viveu.

Por isso a janela (`MarketCalendar.SessionWindow`) é ancorada **na cotação, não
no relógio**: com uma cotação `.dailyClose` é a sessão de onde esse fecho veio,
fechada dos dois lados; com qualquer fonte viva é a sessão em curso, aberta. Os
lotes classificam-se em três, e não em dois:

| Lote | Referência | Porquê |
|---|---|---|
| anterior à janela | fecho anterior | viveu a sessão inteira |
| dentro da janela | `max(fecho anterior, preço de compra)` | viveu parte dela |
| posterior à janela | **nada, contribui 0** | não existia durante a sessão reportada |

O zero do terceiro caso não é um valor por defeito: é o número verdadeiro. A
posição não se moveu desde que foi comprada, porque não há preço mais recente
para onde se ter movido.

### Generalização: 1D é um caso de `PerformancePeriod`

O "Hoje" era o único período no cabeçalho. Agora o cabeçalho expõe sete
períodos — 1D · 1S · 1M · 3M · 6M · 1A · YTD — num seletor de segmentos
horizontal (o mesmo componente visual do `rangePicker` do gráfico de detalhe).

**Um só caminho de cálculo.** `periodChangeTotal` despacha para
`dayChangeTotal` quando o período é `.oneDay`, e para `changeTotal` com um
`cutoffDate` nos restantes. Toda a lógica das regras 1–3 acima continua a
aplicar-se exclusivamente ao caso 1D; os outros períodos medem-se contra o
fecho mais recente na cache de candles que esteja antes do cutoff.

**Referência vinda da cache, nunca da rede.** O `referenceCloseLookup` é
injetado pelo `PortfolioScreen` e aponta para `CandleStore.series(for:)`.
Trocar de segmento recalcula a computed property sem disparar pedidos de rede.
Se um ativo não tem histórico que chegue ao cutoff, entra como `nil` e o total
fica marcado `isPartial`.

**Persistência.** O período selecionado é gravado em `UserDefaults`
(`selectedPerformancePeriod`) e restaurado na próxima abertura.

---

## 6. Totais: onde o parcial é aceitável e onde não é

**O cabeçalho aceita o parcial.** `marketValueTotal` soma as posições que têm
cotação e devolve, junto com o número, quais é que ficaram de fora. O ecrã
recusa desenhar o número sem desenhar também a ressalva. Devolver `nil` à
primeira posição sem preço era defensável e inútil: um ETF sem cotação escondia
388 € de NVDA.

**A alocação não aceita.** Se alguma posição não tiver cotação,
`PortfolioAllocation` devolve `.unpriced([símbolos])` e o ecrã nomeia-os em vez
de desenhar o anel. A diferença é deliberada: uma ressalva funciona ao lado de um
número, não ao lado de um gráfico. Uma fatia é uma afirmação sobre o **todo**, e
uma fatia calculada sobre um todo incompleto está errada mesmo quando a
aritmética está certa.

**O snapshot também não aceita.** `PortfolioSnapshotRecorder` só grava carteiras
totalmente cotadas, usando o total estrito. Um ponto guardado não tem ressalva ao
lado, e daqui a um ano não há como distinguir uma queda real de uma falha de
provider.

**O custo acompanha o valor.** O custo é somado sobre exatamente as mesmas
posições que o valor. Dividir um valor parcial por um custo total é como um
−12 % se transforma em −45 %.

---

## 7. O gráfico é desenhado na moeda da listagem, sem converter

O gráfico do detalhe não converte para EUR. As velas são o histórico do
instrumento na praça onde ele é negociado; converter cada ponto exigiria a taxa
de câmbio **daquele dia**, e a app tem taxas diárias do Frankfurter só para os
dias que já pediu. Aplicar a taxa de hoje a uma série de um ano desenharia
movimento cambial como se fosse movimento do ativo — uma linha que mistura duas
coisas e não permite ler nenhuma.

Por isso o eixo é rotulado com a moeda nativa e os números em euros (preço médio,
custo, valor, P/L) ficam nos campos, onde cada um é um valor único e convertível
com uma taxa única. `AssetDetailViewModel.nativeCurrency` é a moeda da listagem
gravada, não a do provider.

Na linha da carteira, uma posição não-euro mostra `223,96 USD × 0,8669`. Uma
figura em euros derivada de um preço estrangeiro é inverificável sozinha: 388,32 €
não se distingue de 194,16 USD por ação sem ver a taxa. E essa linha **encolhe em
vez de truncar** — `× 0,86…` não é uma taxa abreviada, é outra taxa.

### Decisão: a pesquisa **ordena**; só exclui o que não é um ativo

`SearchRanking` faz duas coisas separadas, e a fronteira entre elas é a regra:

**Excluir** é para o que não é um ativo comprável — notas estruturadas (a
"Capped Point to Point" do Barclays, a "Dual Directional Buffer Note" do
JPMorgan) e embrulhos tokenizados ("Apple xStock", os "Ondo"). Uma nota
estruturada é uma aposta que *referencia* a ação, e um token é um direito sobre
um custodiante. Recibos de depósito (CEDEAR, BDR) **não** são excluídos: são o
ativo comprado de outra maneira.

**Ordenar** é para tudo o resto, incluindo os ETP alavancados. Um QQQ3 ou um
3GOL é um instrumento real, listado, com ISIN e preço — e está nesta carteira.
Filtrá-los pelo nome só funcionava enquanto o utilizador escrevesse um ticker
que o filtro por acaso poupava: procurar "WisdomTree" ou "gold 3x" — que é como
se procura um instrumento cujo símbolo não se sabe de cor — apagava a resposta.
Um filtro que apaga o que estamos a procurar é pior do que uma ordem má, porque
uma ordem má vê-se e um filtro não.

Por isso `derivativeFundMarkers` desce em vez de apagar, e a comparação entra na
ordenação **abaixo da identidade e acima da praça**: procurar AAPL põe o AAPL do
NASDAQ em primeiro e os 2x lá em baixo; procurar QQQ3 põe o QQQ3 em primeiro,
porque o match exato de ticker já decidiu antes; procurar "gold" põe o ETC
físico à frente do 3x, seja qual for a praça de cada um — ser a coisa simples
vale mais do que estar listado em casa. O nome completo fica visível na linha,
para o 3x se ver.

### Decisão: um ticker exato de cripto vem antes das ações que o carregam

As regras de ordenação acima da praça foram todas escritas para **listagens**: a
listagem primária e a ordem regional leem um MIC, e uma moeda não tem nenhum —
não está listada em lado nenhum, negoceia em todo o lado. Uma linha do CoinGecko
caía por isso em `.other` rank 50 e ficava debaixo de tudo o que partilhasse o
ticker: procurar BTC dava o trust da Grayscale, a Melanion, a Vinanz e uma
empresa de saúde australiana, com o Bitcoin lá em baixo. Os resultados chegavam
todos (o log confirma-o: 30 + 8 = 38); o que estava mal era a ordem.

**Regras de bolsa a arbitrar uma coisa que não tem bolsa** — não a cripto tratada
como categoria inferior. É o padrão do `NVD` com outra roupagem: a pergunta está
certa, o objeto é que não é aquele. Lá, `quotes["NVD"]` perguntava "qual é o
preço deste ticker?" a um ticker que era dois instrumentos; aqui,
`primaryListingIDs` e `venue(for:)` perguntam "qual é a praça principal disto?" a
uma coisa que não está listada em lado nenhum. Nos dois casos o código não tinha
defeito nenhum de lógica: aplicava corretamente uma regra a um objeto que ela não
descreve. Vale a pena procurá-lo pelo sintoma — uma resposta absurda saída de
código que se lê bem —, porque é assim que se apresenta das duas vezes.

As regras de praça não estão erradas — é que **não se aplicam** aqui. Por isso a
identidade decide antes delas: entre os matches exatos de ticker, a cripto vem
primeiro. BTC é o Bitcoin, ETH é o Ethereum, e os fundos e empresas com esses
nomes seguem-se. Só o match **exato** o faz: procurar "Bitcoin Group" é uma
pesquisa por nome, e nada promove a moeda por cima da empresa que é a resposta.

E o eco: o Twelve Data devolve "BTC · Bitcoin · EUR" como instrumento vulgar. É
o mesmo ativo pela via de preço errada, portanto nunca tem cotação — ficaria
imediatamente por baixo da moeda, com o mesmo nome e um travessão. Elimina-se
por **ticker e nome em conjunto**, nunca só pelo ticker: a "Bitcoin Group SE" é
uma ação alemã a sério e tem de sobreviver a uma pesquisa por Bitcoin, e uma
empresa que apenas partilha o símbolo de uma moeda é outro instrumento e merece
a sua linha. Das duas cópias, a que fica é a que cota.

### Decisão: a unidade é uma propriedade da **linha**, nunca da praça

Londres e Milão entraram no routing a 2026-08-14, porque uma posição em 3GOL
(XMIL) estava em travessão: nenhuma das duas praças estava em tabela nenhuma. O
que se descobriu a caminho é mais importante do que a rota.

`MarketCalendar.alphaVantageCurrency(forSuffixOf:)` respondia `GBp` a `.LON`,
com base numa leitura real: `VOD.LON` dá 120,15 para uma ação a 1,20 £. A
premissa — a praça decide a unidade — é **falsa**, e mediu-se em direto no mesmo
dia: `3GOL.LON` dá 155,48, e essa linha da LSE cota em **dólares** (o Yahoo, no
dia seguinte, diz `3GOL.L` = 158,47 **USD**). A linha em pence do mesmíssimo ETP
é outro ticker, `3LGO`, perto de 10 950 GBp. Uma praça, duas linhas, duas
unidades — e o sufixo não as distingue.

Dividir as duas por 100 punha o 3GOL a 1,55 com um rótulo GBP, e a seguir uma
taxa GBP→EUR por cima. Por isso a resposta passou a ser **não responder**: sem
leitura da unidade, o Alpha Vantage não devolve cotação nem série. Um travessão
sara quando se acrescenta uma rota; um número 100× errado com a moeda errada
parece plausível e contamina o custo, o total e a alocação.

Londres não fica por isso sem preço: vai ao último recurso, que **reporta a
moeda por linha** (`GBp` no VOD, `USD` no 3GOL) e não precisa de tabela nenhuma.
A tabela de praças do Yahoo passou a ter `currency` **opcional**, e a LSE e
Borsa Italiana entram com `nil`: uma praça sem moeda única não pode ter uma
moeda escrita à mão, e uma resposta que não a diga não produz cotação.

O corolário está em `hasQuoteRoute(mic:)`: a pesquisa deixou de oferecer como
comprável o que a app não consegue cotar. Uma linha numa praça sem rota mostra
**"sem cotação"** antes da compra, em vez de o portfólio o dizer com um
travessão depois. O convite e a capacidade passaram a ser a mesma tabela.

### Decisão: sub-unidades normalizam-se na fronteira, no histórico como na cotação

Londres cota em **pence**, não em libras. Os providers reportam o código da
sub-unidade como se fosse moeda (`GBp`, `GBX`; e `ZAc`, `ILA` noutras praças),
e lê-lo como unidade maior põe todos os valores 100× acima. A regra é uma só:
**converter na fronteira de parsing** — código para a unidade maior, preço a
dividir — e nunca mais abaixo.

A parte que faltava era o **histórico**. As velas passavam sem normalização, o
que não é uma imprecisão cosmética: a Camada 2 compara o preço publicado com o
último fecho em cache e recusa acima de 10×. Uma série em pence ao lado de uma
cotação em libras é exatamente 100×, portanto era o preço **correto** que era
recusado, e a posição mostrava travessão com o gráfico e a cotação a parecerem
individualmente razoáveis. Um erro de escala no histórico não se lê como um erro
de escala: lê-se como ausência de dados.

Os dois providers de histórico chegam lá por caminhos diferentes, porque só um
declara a unidade:

- **Twelve Data** reporta `meta.currency` no `/time_series` — verificado em
  chamada real — tal como reporta `currency` no `/quote`. O divisor vem do
  payload.
- **Alpha Vantage não reporta unidade nenhuma**, nem no `GLOBAL_QUOTE` nem no
  `TIME_SERIES_DAILY`, cuja "Meta Data" tem informação, símbolo, última
  atualização, tamanho e fuso — e nada sobre unidades. E, verificado em direto,
  responde a `VOD.LON` com **119,20** para uma ação que negoceia a 1,19 £. O
  sufixo pedido é a única coisa que distingue libras de pence, e é de lá que sai
  o divisor (`MarketCalendar.alphaVantageCurrency(forSuffixOf:)`, que devolve
  `GBp` para `.LON` de propósito, para passar pela mesma normalização).

Cotação e vela saem por isso da **mesma** função por provider. Eram duas funções
obrigadas a concordar e não concordavam; o teste que as prende percorre o produto
(provider × praça) e afirma sobre a igualdade das duas, não sobre exemplos.

O volume nunca se divide: é uma contagem de ações, não um preço.

---

## 8. A conta é tesouraria, não uma partição do portfólio

A posição é **uma por ativo** (por listagem, desde o ponto F). A conta indica de
onde saiu o dinheiro na compra e para onde vai na venda — é tesouraria. As
unidades pertencem todas ao mesmo monte, e o custo médio é o do monte todo.

**Porquê:** o modelo anterior — uma posição por (ativo, conta) — quebrou de duas
maneiras. Primeiro, uma venda de BTC feita na conta Santander, onde nunca se
comprou BTC, era recusada: a conta não tinha unidades, embora o utilizador
tivesse 0,002892. Segundo, o P/L realizado de uma venda era calculado contra o
custo médio daquela conta e não contra o custo médio real (o de todos os lotes
de BTC comprados em qualquer conta), porque a posição da conta tinha a sua
própria série de compras e o seu próprio custo médio.

Consequências desta decisão:

- `computeHoldings` agrupa por `listing.storageKey`, não por
  `listing.storageKey + accountID`. O `Holding` resultante tem `accountID: ""`
  e `accountName` junta os nomes das contas de compra.
- `perAccountHoldings` existe para a alocação por conta. Parte da posição
  unificada e proporcionaliza o custo pelas compras de cada conta — é a
  projeção, não a verdade de registo. A soma das projeções bate com o total
  exatamente porque ambas derivam do mesmo monte.
- A validação da venda (`sellMoreThanTotalIsRefused`) compara com a quantidade
  total, não com a quantidade na conta de destino. O formulário mostra
  "Disponível: X" com o total unificado.
- O detalhe da posição recebe `accountID: ""` e mostra todas as transações de
  todas as contas.

**A tentação que regressa.** Isto é a segunda vez que a linha da posição muda de
significado — primeiro deixou de ser por conta na unificação, agora a conta
deixou de ter qualquer relação com as unidades. A simetria superficial
(conta ↔ posição) parece natural, e alguém vai querer restaurá-la para
"arrumar" o modelo. O que se está a arrumar é o invariante de que a quantidade
de um ativo pertence ao portfólio e não a uma conta, e a arrumação ressuscita
exactamente os dois bugs acima.

---

## 9. Regras invioláveis

1. Preço em falta, câmbio em falta ou preço zero → `marketValueEUR` é `nil` →
   travessão, e fora de todos os totais. Um zero não é uma cotação: satisfazia
   `let price = currentPriceNative`, produzia 0,00 € e mostrava −100,00 %.
   O mesmo para o fecho anterior: sem ele não há "Hoje", e a posição mantém
   valor e P/L. Ausência nunca vira zero na fronteira de parsing.
2. Zero lógica financeira nas Views.
3. `PortfolioCalculator` é pura. Sem I/O, sem SwiftData, sem `PriceStore`.
4. Custo do vendido: `totalCostEUR * (qty / quantity)`, nunca `avgPrice * qty`.
5. `QuoteSource` e afins são `Codable` persistidos — **acrescentar casos é
   seguro, remover ou renomear parte snapshots já gravados**.
6. Apagar em SwiftData é um a um, com fetch. Batch delete não é fiável aqui.
7. Chaves de API nunca no código. `Secrets.plist`.
8. Nenhum dado simulado chega ao ecrã sem o ecrã o dizer (`isUsingMockData`).

---

## 10. Testes

532 testes, sem falhas. A organização segue uma lição repetida três vezes:

**Testar o calculador não prova nada sobre o ecrã.** Os 10 testes de
`DayChangeAndPlausibilityTests` ficavam verdes com o bug da fronteira de sessão
presente, porque todos usavam `today = startOfDay(now)` e nunca atravessavam a
fronteira. Os testes que apanham este tipo de defeito entram por SwiftData +
`PriceStore` e leem a propriedade que a View lê
(`PortfolioViewModelDayChangeTests`, `EndOfDaySessionWindowTests`,
`RecordedCurrencyTests`).

**Um guard novo é verificado por mutação.** Anula-se o guard, confirma-se que os
testes ficam vermelhos, restaura-se. Um guard cujos testes passam com ele anulado
não está testado, está acompanhado.

**Um layout é renderizado, não lido.** `PositionRowLayoutTests` desenha a linha
com `ImageRenderer` a 375, 402 e 440 pt e afirma sobre a altura resultante. O
`layoutPriority` que parecia certo no código fazia o preço quebrar um algarismo
por linha, e nenhuma leitura do ficheiro mostrava isso.

**Uma taxa de 1 não testa uma conversão.** Inverter a direção do câmbio falhava
1 teste em 464, e a causa não era a injeção: era que quase todas as posições dos
testes valem à taxa 1, que é o ponto fixo da inversão — multiplicar e dividir por
1 dá o mesmo. Acrescentar mais testes desses não teria ajudado nada.
`FXDirectionTests` fixa a **propriedade** sobre um produto cartesiano de quatro
moedas cujas taxas estão longe de 1 e longe do próprio inverso, e os dois
helpers partilhados que injetavam a taxa passaram a percorrer o provider.
Números em `INVENTARIO_PENDENCIAS.md`.
