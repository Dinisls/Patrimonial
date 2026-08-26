# Inventário de pendências — módulo de investimentos

**Estado a 14 de agosto de 2026.** 504 nomes de teste distintos, zero falhas.

O módulo tinha fechado com 495; reabriu no mesmo dia para dois pontos desta
lista — R6 (Londres e Milão sem rota de cotação, que era uma posição real em
travessão) e a parte do R1/R4 que o resolver desenterrou. Ambos passaram a
Fechados, e o que mudou está escrito nas respetivas secções em vez de apagado.

Continuação da auditoria da família "valor entra sem verificação de
plausibilidade" (15 achados, entregues a 2026-08-09). As letras são as
originais, para o histórico não se perder.

Este documento é um **mapa, não uma lista de trabalho**. Está organizado por
três níveis, na ordem em que interessam:

1. **RISCO CONHECIDO** — pode produzir um número errado ou perder dados, mesmo
   que hoje não dispare.
2. **FUNCIONALIDADE INCOMPLETA** — funciona, está por acabar. Não mente.
3. **DÍVIDA DE TESTES** — sítios onde o teste não exercita o caminho real.

Os custos são ordens de grandeza, não estimativas: **pequeno** = uma a duas
horas com testes; **médio** = uma sessão; **grande** = mais do que uma sessão,
ou uma decisão de desenho antes de começar.

---

## Fechados

| | O quê | Fechado em |
|---|---|---|
| A, B, C, D | Identidade de listagem, colisão de ticker NVD | 2026-08-09 |
| H | Zero na fronteira de parsing | 2026-08-09 |
| Camada 2 | Plausibilidade contra o histórico próprio (10×) | 2026-08-09 |
| — | "Hoje" por lote, e depois por sessão em vez de dia de calendário | 2026-08-09 |
| **F** | `ListingID` em todo o lado, backfill inequívoco, guard do `venueConflict` estreitado | 2026-08-10 |
| **E** | Moeda gravada só imposta depois da praça confirmada; `currencyAgreesWithRecordedListing` para listagens sem MIC. `rekeyed` deixou de deitar fora o `venueMIC` | 2026-08-10 |
| **L** | Caminho real do câmbio coberto por `CurrentFXRefreshChainTests` | 2026-08-10 |
| — | Fim da janela de sessão: um lote comprado depois do fecho reportado contribui 0 | 2026-08-10 |
| — | Linha da carteira: preço deixou de quebrar um algarismo por linha | 2026-08-10 |
| **I** | `previousClose` e as variações passaram a opcionais em `Quote` e `PriceSnapshot`; `?? price` removido dos **quatro** providers | 2026-08-10 |
| **J** | `FrankfurterProvider` compara `decoded.base` com o pedido e recusa o resto | 2026-08-10 |
| **K** | `formatDate` com `en_US_POSIX` e calendário gregoriano | 2026-08-10 |
| **N** | Variação de 24 h ausente no CoinGecko já não vira 0 % | 2026-08-10 |
| — | `FXRate` com direção; conversão feita pela taxa, que recusa moeda errada | 2026-08-10 |
| — | `.closed` e `.dailyClose` separados por forma, com legenda em três ecrãs | 2026-08-10 |
| — | Sub-unidades (`GBp`/`GBX`, `ZAc`, `ILA`) normalizadas na cotação e na pesquisa | 2026-08-13 |
| — | **Sub-unidades no histórico.** As velas passavam sem normalizar nos dois providers. Twelve Data pelo `meta.currency`; Alpha Vantage pelo sufixo, porque não reporta unidade nenhuma | 2026-08-14 |
| — | ETP alavancados deixaram de ser filtrados da pesquisa; passam a ser **ordenados** | 2026-08-14 |
| — | Pesquisa de cripto tem prioridade sobre o polling no orçamento do CoinGecko | 2026-08-14 |
| **Q** | **Não havia falha de obtenção.** O log nomeado mostrou 30 ações + 8 criptos combinadas em todas as rondas; os "cancelled" eram o debounce a limpar tentativas intermédias. O defeito era a ordenação, abaixo | 2026-08-14 |
| **R6** | **Londres e Milão passaram a ter rota de cotação** (Yahoo, `.L` e `.MI`), verificadas em direto. A pesquisa deixou de oferecer como comprável o que não consegue cotar: `hasQuoteRoute(mic:)` e a etiqueta "sem cotação" na linha | 2026-08-14 |
| **R1/R4 (parte)** | **O Alpha Vantage deixou de adivinhar a unidade.** `.LON` já não responde `GBp` — na LSE a unidade é da linha, não da praça — e um ticker nu já não cai em USD: sem leitura, não há cotação nem série | 2026-08-14 |
| — | **Cripto com ticker exato passa à frente.** Regras de praça (listagem primária, ordem regional) arbitravam uma coisa sem praça e empurravam o Bitcoin para o fundo. E o eco do Twelve Data ("BTC · Bitcoin · EUR", sem cotação possível) é deduplicado por ticker **e** nome | 2026-08-14 |

---

## 1. RISCO CONHECIDO

Por ordem de exposição. Nenhum destes é um defeito a disparar hoje; todos são
sítios onde uma condição plausível produz um número errado ou perde informação.

### R1 — G: o que sobra depois de o Alpha Vantage deixar de adivinhar

**Fechado o pior a 2026-08-14.** `normalization(forSymbol:)` devolve agora
`nil` quando o símbolo não diz a unidade, e `toQuote`/`decodeCandles` recusam em
vez de produzir. O fallback `exchangeForSymbol(...).nativeCurrency`, que
respondia USD a qualquer coisa que não reconhecesse, desapareceu.

**O que fica.** `exchangeForSymbol` continua a devolver `.nyse` por omissão, e é
lido noutros sítios — `MarketCalendar.isEuropean`, o filtro do próprio provider,
a janela de sessão de um símbolo com ponto. Um sufixo desconhecido (`QQQ3.LON`,
`X.SW`) continua a ler-se como NYSE nesses caminhos.

*Risco:* baixo, e agora contido: quem pergunta a moeda já recebe `nil`. O que
resta é routing, não rotulagem — a pior consequência é uma praça perguntada ao
provider errado, que responde nada.

**Custo:** pequeno. Dar a `exchangeForSymbol` um irmão opcional e usar esse nos
sítios que não toleram um palpite.

### R2 — O Yahoo depende de um User-Agent de browser, e falha em silêncio

**O que é.** `YahooChartProvider` manda um User-Agent de Safari
(`YahooChartProvider:87`) porque o endpoint responde 429 a um cliente sem
adornos. Não há chave nem quota: é o mínimo para o endpoint responder de todo. E
`decodeQuote` **nunca lança** — devolve `nil` — por desenho, para que um
problema do Yahoo não possa virar um erro de carteira.

**O que pode correr mal.** É o único provider que chega a onze praças —
Frankfurt, Munique, Düsseldorf, Hamburgo, Suíça, Viena, Varsóvia, Buenos Aires,
Cidade do México, Toronto e Bogotá — e é a quarta rede das quatro europeias. Se
o Yahoo apertar o filtro, ou mudar o formato, todas essas posições passam a
travessão **sem um único sinal**: sem erro, sem log, sem indicador. O total da
carteira passa a somar menos posições e a assinalar as excluídas, que é o
comportamento correto, mas ninguém fica a saber *porquê*. Nenhum teste cobre
isto: nenhum teste desta suite faz um pedido HTTP (ver D1).

**Medido a 2026-08-14.** O `curl` e o `python` desta máquina levam **429 em
todos os endpoints JSON** do Yahoo, incluindo o `getcrumb` e incluindo `AAPL`;
o `URLSession`, com o mesmo User-Agent, responde **200** a `3GOL.MI`, `3GOL.L`,
`VOD.L` e `AAPL`. Não é o header sozinho: é o cliente. O risco confirma-se como
está escrito — a rota depende de uma condição que ninguém declara e que muda sem
aviso — e agora carrega mais peso, porque Londres e Milão passaram a depender
**só** dela (o Alpha Vantage não serve Milão, verificado: resposta vazia; o
Twelve Data grátis responde 404 "Pro or Venture plan" a XMIL em todos os
endpoints).

**Custo:** médio para o sinal — registar por provider a última resposta boa e
mostrar "fonte indisponível" em vez de só o travessão. Grande para substituir a
fonte, e não há candidato grátis que cubra estas praças.

### R3 — Alpha Vantage `compact`: 100 sessões, e o histórico é a segunda opinião

**O que é.** `dailyCandles` pede sempre `outputsize=compact` — as últimas 100
sessões — porque `full` é premium. O gráfico longo só se constrói acumulando
respostas ao longo do tempo, e é por isso que a cache nunca apaga.

**O que pode correr mal.** Duas coisas, e a segunda é a que interessa. A
primeira é cosmética e já está declarada: 1A e Máx nascem incompletos e o ecrã
diz que a cobertura é parcial. A segunda é que a **Camada 2 usa o histórico como
segunda opinião**: `PriceStore.isPlausible` compara o preço publicado com o
último fecho conhecido e recusa acima de 10×. Sem histórico não há comparação —
`referenceClose` devolve `nil` e a função devolve `true`. Uma posição europeia
recém-adicionada está, durante o tempo em que a cache está vazia, exatamente tão
desprotegida contra um ticker trocado como estava antes de existir a Camada 2. É
uma janela, não um buraco permanente, mas é a janela em que mais se mexe na
carteira.

**Custo:** o `full` é uma decisão comercial, não técnica. Mitigar é pequeno:
tornar visível que uma listagem ainda não tem segunda opinião, em vez de a
ausência ser indistinguível de um "passou".

### R4 — A normalização de sub-unidades cobre os casos que encontrámos

**O que é.** `CurrencyNormalization.normalize` (Quote.swift:148) é um `switch`
sobre a string crua com cinco códigos em quatro casos: `GBp`, `GBX`, `ZAc`,
`ZAR¢`, `ILA`. O
`default` devolve o código tal e qual com divisor 1.

**O que pode correr mal.** Três formas, todas silenciosas:

- **Caixa.** A comparação é sensível a maiúsculas. `GBX` está lá, `gbx` não;
  `ZAc` está, `ZAC` não. Um provider que mude a grafia passa a 100×.
- **Códigos que faltam.** Qualquer praça que cote em sub-unidade e que ainda não
  nos apareceu entra pelo `default` e sai 100× acima.
- **O modo de falha é o pior possível.** Não é um número visivelmente absurdo: a
  Camada 2 vê 100× e **recusa o preço correto** quando o histórico está na
  unidade certa, ou aceita a série errada quando é o histórico que vem em
  sub-unidade. Foi exatamente este o defeito das velas, fechado a 14 de agosto,
  e a lição é que o sintoma não aponta para a moeda.

**Aconteceu, a 2026-08-14.** Não com um código novo: com o `.LON` do Alpha
Vantage, que assumia pence para uma praça onde a unidade é da linha. Ver a
decisão no `MODULO_INVESTIMENTOS.md`. A correção foi recusar, e é o precedente
para a política em aberto abaixo.

**Custo:** pequeno para a caixa e para acrescentar códigos. **Médio** para a
parte que interessa, que é a política: um código de moeda desconhecido devia ser
motivo de recusa em vez de ser aceite com divisor 1? Isso é uma decisão, e muda
o comportamento de todas as praças que ainda não modelámos.

### R5 — A taxa de câmbio da compra continua um `Decimal` sem direção

**O que é.** A taxa viva tem tipo (`FXRate`, que sabe o que converte em quê e
recusa a moeda errada). A **histórica**, `Transaction.assetFXRate`, é um
`Decimal` nu persistido em SwiftData, e a transação não grava a moeda nativa de
que essa taxa converte.

**O que pode correr mal.** Uma taxa gravada ao contrário é indistinguível de uma
taxa certa, e multiplica em vez de dividir: um custo de aquisição errado, que
contamina a mais-valia e o total investido — números que não se comparam com
nada e portanto não denunciam o erro. Coberto de lado por E e pela recusa a
jusante, mas é a última superfície do módulo onde uma direção é convenção e não
facto. E é a que os testes menos apanham (ver D3).

**Custo:** médio. Uma coluna nova (a moeda de origem), migração dos movimentos
existentes e reconstrução da direção onde ela for inequívoca — não onde não for.

### R6 — Fechado: Londres e Milão têm rota; o gráfico continua a não ter

**Cotação, resolvida a 2026-08-14.** `XLON` → `.L` e `XMIL`/`MTAA` → `.MI` na
tabela do Yahoo, que é o único provider que lá chega — verificado em direto:
`3GOL.MI` 136,81 EUR, `3GOL.L` 158,47 USD, `VOD.L` 121,55 GBp. As duas praças
entram com `currency: nil`, porque nenhuma tem moeda única.

**O que fica aberto** é o histórico, e não por esquecimento: o Yahoo recusa
servir velas de propósito, o Alpha Vantage não serve Milão e responde a Londres
sem dizer a unidade, e o Twelve Data grátis está fechado às duas. Uma posição
nestas praças tem preço e não tem gráfico — ver F3, que passa a ser a única
parte por fazer.

*Risco:* nenhum, agora. É ausência declarada.

### R7 — `?? 0` residuais

- `PortfolioSnapshotRecorder:44` — `totalMarketValue(open) ?? 0`. Inócuo hoje,
  porque o gravador já exige carteira totalmente cotada antes de chegar aqui. O
  zero está lá à espera de que essa pré-condição mude, e um snapshot a zero não
  se distingue de um dia em que a carteira valia zero: é histórico corrompido,
  não um ecrã errado que se recarrega.
- Volumes e timestamps nos providers. Não entram em nenhum total monetário.

**Custo:** pequeno. Listados para não voltarem a ser descobertos como novidade.

---

## 2. FUNCIONALIDADE INCOMPLETA

Funciona o que está; o que falta está declarado no ecrã e não finge.

### F1 — Não existe editor de um investimento, em lado nenhum

**O que é.** `TransactionEditSheet` mostra um investimento em **só leitura**
(`PBForms.swift:509`) e diz porquê: não tem campos para símbolo, quantidade,
preço unitário, câmbio ou comissão, e gravar por ali apagaria a posição. O texto
remete o utilizador para o separador Investimentos — **onde também não há
editor**. Os únicos pontos de entrada são `AddPositionSheet` (adicionar) e
apagar.

**O que pode correr mal.** Nada em silêncio: é uma ausência, não um erro. O
custo real é de utilização — corrigir um engano num lote significa apagar e
voltar a introduzir, e apagar/reintroduzir é a operação com mais superfície de
erro que a app tem (data, câmbio histórico, comissão).

**Custo:** médio. O formulário existe em `AddPositionSheet` e a validação
também; o trabalho é o caminho de escrita — editar um movimento tem de
revalidar a identidade da listagem (praça e moeda gravadas), que é precisamente
o que E e F protegem.

### F2 — FIFO para o Anexo G não está implementado

**O que é.** `CostBasisMethod` tem os dois casos, e
`PortfolioCalculator.computeHoldings` lança `CalculationError.methodNotImplemented(.fifo)`
à cabeça (linha 93). Tudo é custo médio.

**O que pode correr mal.** Nada, hoje: o método nunca é escolhido e o erro é
explícito em vez de silencioso. O que falta é fiscal — o Anexo G é FIFO por
lote, e o custo médio dá uma mais-valia diferente. Quem usar estes números para
a declaração usa-os errados, e é a única funcionalidade em falta cujo produto
sai da app para um sítio onde o erro tem consequência.

**Custo:** grande, e a parte cara não é o FIFO. É que uma mais-valia por lote
precisa da taxa de câmbio **de cada lote** com direção conhecida (ver R5), da
comissão imputada por lote e das vendas parciais ordenadas — mais o cenário das
transferências entre contas. O algoritmo é meia sessão; os dados que ele exige
são o resto.

### F3 — Londres e Milão não têm gráfico (ponto P)

**O que é.** Sem caso no `Exchange`, `AssetDetailViewModel.route` devolve `nil`
e o ecrã declara-o (`hasNoHistoryProvider`). Desde 2026-08-14 estas praças têm
**cotação** (R6) e continuam sem histórico, e agora sabe-se porquê em cada
provider: o Twelve Data grátis responde 404 "Pro or Venture plan" a XMIL e a
XLON; o Alpha Vantage não conhece Milão (resposta vazia a `.MI` e `.MIL`) e
responde a `.LON` sem dizer a unidade, que é precisamente o que o deixou de
poder servir; e o Yahoo recusa velas de propósito, para não se tornar uma fonte
de histórico sem alguém o decidir.

É também a razão por que o defeito das velas em pence esteve **latente** e não
visível: o caminho que as produziria nunca era percorrido.

**Custo:** grande, e hoje **bloqueado por plano**, não por trabalho: nenhuma
fonte grátis serve séries destas duas praças. A alternativa barata é honesta e
já existe — dizer no ecrã que não há histórico — e a cara é o Twelve Data pago.

### F4 — Praças com cotação e sem gráfico, por desenho

**O que é.** As secundárias alemãs (XFRA, XMUN, XDUS, XHAM), Buenos Aires,
México, Bogotá, Toronto, Suíça, Viena e Varsóvia recebem cotação do Yahoo e não
têm histórico: `exchangeForMIC` devolve `nil` para elas, logo `route` é `nil`.

**O que pode correr mal.** Nada — é a troca acordada e está dita no ecrã: o
Yahoo não é fonte de histórico e `candles()` lança de propósito para não poder
tornar-se uma sem alguém decidir.

**Custo:** grande e provavelmente mau negócio. Cada praça nova custa horário,
feriados e sufixo, e nenhuma destas é onde esta carteira compra.

---

## 3. DÍVIDA DE TESTES

A lista honesta, depois de tudo o que apanhámos. A pergunta em cada linha é a
mesma: **o teste percorre o caminho, ou injeta o resultado?**

### D1 — Nenhum teste desta suite faz um pedido HTTP, nem substitui a `URLSession`

Zero ocorrências de `URLProtocol` ou de uma sessão de teste nos 36 ficheiros de
teste. O
que os testes de provider cobrem é a **descodificação** de fixtures capturadas
em direto (35 testes chamam `decode(`) e os guards que devolvem *antes* da rede
(`missingKeyThrowsRatherThanCallingOut`, `providerItselfIgnoresNonEuropeanSymbols`,
`candlesAreRefused`).

**Fica por exercitar:** a construção do URL e dos parâmetros, o header
User-Agent do Yahoo (R2), o mapeamento de estado HTTP — em particular 429 →
`rateLimited`, que é o diagnóstico que passámos a distinguir no log da pesquisa
de cripto —, os timeouts e o comportamento perante uma resposta truncada. Ou
seja: a metade dos providers que fala com o mundo é a metade que nenhum teste
vê.

**Custo:** médio, e paga-se uma vez. Um `URLProtocol` de teste e uma
`URLSession` configurada com ele; depois cada provider ganha três a cinco testes
pequenos. É a dívida com melhor retorno da lista.

### D2 — A cotação: 42 testes injetam, 40 percorrem

`applyQuote` aparece em 42 blocos `@Test`, `refresh` em 40 e `quotesForSearch`
em 10. A proporção está muito melhor do que estava, mas a distribuição é
desigual: das quatro pernas do fallback, só a europeia tem um teste dedicado ao
routing (`europeanListingsReachTheAlphaVantageFallback`). A perna do último
recurso — a que chega às onze praças do R2 — é exercitada por mocks que não
distinguem qual provider respondeu.

**O que pode estar escondido:** uma listagem que devia ir ao último recurso e vai
ao europeu, ou vice-versa, produz uma cotação plausível vinda da fonte errada.
Com mocks complacentes os dois caminhos devolvem o mesmo número.

**Custo:** pequeno. Um duplo por perna que **grava quem foi perguntado**, e
asserções sobre o pedido em vez de sobre o número — foi o que resolveu o câmbio
no ponto L (`StubFXProvider.calls`), e o padrão transfere-se tal e qual.

### D3 — O câmbio histórico, e a taxa 1 que ainda cega

O câmbio **vivo** está resolvido: só 4 testes ainda injetam com
`setCurrentFXRateForTesting`, contra 25 que percorrem o provider, e
`FXDirectionTests` cobre o produto cartesiano de quatro moedas com taxas longe
de 1 e do próprio inverso.

O **histórico** não. **41 dos 495 testes escrevem `fxRate: 1`** nas suas
fixtures, e 1 é o ponto fixo da inversão: multiplicar e dividir dão o mesmo
número. Enquanto `assetFXRate` for um `Decimal` sem direção (R5), estes 41
testes não conseguem, por construção, detetar uma direção trocada no custo de
aquisição.

**Custo:** pequeno mudar as fixtures para taxas longe de 1 — e é o que se deve
fazer já, independentemente de R5. Fechar a causa é médio e está em R5.

### D4 — Duplos que respondem a perguntas que não deviam saber responder

O princípio já está adotado onde dói mais: `MockFXRateProvider` e `StubRate`
**lançam** para pares que não conhecem em vez de responderem 1, e
`MockMarketDataProvider.answersOnlyKnownSymbols` é `true` por omissão.

O que sobra: três testes desligam essa recusa (`answersOnlyKnownSymbols =
false`) e passam a receber `defaultQuote(symbol:)` — preços sintéticos para
qualquer símbolo. Nesses três, um erro de routing (símbolo mal construído, praça
trocada) devolve um número em vez de nada, que é exatamente o mecanismo que
mantinha o defeito escondido antes.

**Custo:** pequeno. Rever os três e substituir o default sintético por fixtures
nomeadas.

### D5 — A Camada 2 é testada com a closure à mão; o fio real está numa View

`PriceStore.referenceClose` é uma closure injetada, e todos os testes a definem
diretamente (`store.referenceClose = { _ in ... }`). A montagem verdadeira —
ler o último fecho da `CandleStore` para *aquela* listagem — vive em
`PortfolioScreen.swift:107`, dentro de uma View, e não é exercitada por nenhum
teste.

**O que pode estar escondido:** a closure real pode ler a listagem errada (o
ticker em vez da listagem, a chave sem praça) e todos os testes da Camada 2
continuam verdes, porque testam a regra e não a ligação. É a mesma forma do
achado de identidade: a regra certa aplicada ao objeto errado.

**Custo:** pequeno. Extrair a closure para uma função nomeada e testá-la com
duas listagens que partilham ticker — a montagem passa a ser código testável em
vez de uma linha dentro de um `body`.

### D6 — O ecrã, ainda quase todo por fora

O que existe: `PositionRowLayoutTests` mede a linha com `ImageRenderer` (e
aprendeu-se que só a **largura** prova truncamento), e a ordenação da pesquisa
passou hoje a ter teste ao nível do view model — `vm.searchResults`, a
propriedade que a view lê, e não só o comparador.

O que falta: o `ImageRenderer` não renderiza `NavigationStack` (devolve `nil`),
portanto nenhum ecrã completo é fotografável em teste; os estados de erro,
carregamento e vazio das telas de carteira e detalhe verificam-se a olho; e o
target de UI tests não arranca no simulador (`FBSOpenApplicationServiceErrorDomain`,
anterior a este módulo).

**Custo:** grande, e de retorno duvidoso pelo caminho dos UI tests. O caminho
barato é o que se usou hoje: afirmar sobre a **propriedade que a view lê**, com
os providers stubados, o que apanha tudo menos o layout.

### D7 — Migração e reset: cobertos na lógica, não no arranque

`ListingMigrationTests` (12 testes) cobre o backfill inequívoco e os casos
ambíguos, e `DataResetTests` (11) confirma que as nove tabelas e o estado do
`PriceStore` desaparecem. O que nenhum teste faz é correr o **arranque real** —
a sequência em que a migração é invocada na primeira abertura depois de uma
atualização, com um `ModelContainer` que já existia.

**Custo:** médio, e é o género de teste que só se justifica antes da próxima
migração de esquema. Fica registado para quando essa aparecer.

---

## Anexo — sensibilidade do suite, medida

Mantido do ponto L, porque é o que dá crédito aos números da secção 3.

| | Antes | Agora |
|---|---|---|
| injetam a taxa (`setCurrentFXRateForTesting`) | 24 | **4** |
| percorrem o caminho real do câmbio | 2 | **25** |
| injetam a cotação (`applyQuote`) | 65 | 42 |
| percorrem o caminho real da cotação (`refresh`) | 40 | 40 |

### Mutações, medidas

| Mutação | Testes distintos que falham |
|---|---|
| o pedido ao provider é invertido (`from: "EUR", to: currency`) | 1 → **9** |
| a conversão passa a dividir em vez de multiplicar | 4 → **8** |
| a conversão deixa de verificar a moeda do dinheiro | — → **3** |
| `lookupCurrentFX` deixa de verificar o par | — → **0** |
| divisor de sub-unidade fixado a 1 nas velas do Twelve Data e do Alpha Vantage | **3** |
| a demoção de alavancados é removida da ordenação (1ª tentativa) | **0** |
| a mesma demoção, contra o teste refeito | **1** |
| a cripto deixa de passar à frente no match exato de ticker | **4** |
| a deduplicação do eco do Twelve Data é anulada | **2** |

As duas linhas do meio são a lição, não um detalhe. Os quatro testes escritos
para os ETP alavancados passavam todos com a demoção **removida**: a ordem que
afirmavam saía por acaso do desempate seguinte. Um teste que a mutação não
derruba descreve o resultado, não prende a regra. O substituto põe o alavancado
em Lisboa e o simples em Frankfurt, para que todas as outras regras ordenem ao
contrário e só a demoção possa produzir a resposta esperada — e as duas últimas
linhas foram escritas já com esse critério, uma delas a falhar também ao nível
do view model.

A linha dos zero é um resultado, não uma falha. Esse guard é redundante *por
construção*: `refreshCurrentFXRates` recusa gravar uma entrada cujo par não bate
certo, e `setCurrentFXRateForTesting` arquiva pela moeda que a própria taxa diz
converter. O estado mau já não se consegue construir, portanto não há teste que
o possa observar.

### O que estava realmente a cegar o suite

Não era a injeção. Era que quase todas as posições dos testes valem à **taxa 1**,
e 1 é o ponto fixo da inversão. Nenhuma quantidade de testes desses detetaria
uma direção trocada. Por isso a correção não foi converter os 463, mas:

1. dar direção ao tipo, para uma taxa invertida deixar de poder ser aplicada;
2. `FXDirectionTests`, sobre o produto cartesiano de quatro moedas com taxas
   longe de 1 e longe do próprio inverso;
3. `MockFXRateProvider` e `StubRate` deixaram de responder `1` a pares que não
   conhecem — passam a lançar. Um duplo que responde a qualquer pergunta não
   ajuda a encontrar o código que faz a pergunta errada;
4. os dois helpers partilhados de `AssetDetailViewModelTests` e
   `QuickActionAndCalendarTests` passaram a percorrer o provider.

O ponto D3 diz onde é que essa mesma cegueira continua: na taxa histórica.

---

## Dívida técnica (não são defeitos, não são risco)

- **Refrescamento do `AppStore` por `onChange` do separador.** É um remendo:
  outra escrita por outro `ModelContext` volta a dessincronizar. Aceite.
- **Target de UI tests não arranca no simulador.** Anterior a este módulo. Para
  fotografar um separador usa-se `SIMCTL_CHILD_PB_TAB=4 xcrun simctl launch`.
- **`equitySearchProvider` injetável no `PriceStore`.** Acrescentado a
  2026-08-14 só para o teste de ordenação poder percorrer as duas metades da
  pesquisa. A app nunca troca este provider; é superfície que existe para o
  teste, e está assumida como tal.
