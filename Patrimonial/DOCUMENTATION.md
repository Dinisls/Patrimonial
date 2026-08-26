# Patrimonial - Documentação do Projeto

Aplicação iOS de finanças pessoais construída com **SwiftUI** e **SwiftData**.

---

## Arquitetura

```
Patrimonial/
├── Core/
│   ├── Formatters/        → Formatação de moeda e percentagens
│   ├── Networking/        → Cliente HTTP genérico (URLSession)
│   └── Persistence/       → Configuração do SwiftData (schema + container)
├── DesignSystem/
│   ├── Components/        → Card, PrimaryButton, EmptyState
│   ├── Color+Theme.swift  → Paleta de cores (light/dark)
│   └── Font+Theme.swift   → Tipografia do tema
├── Features/
│   ├── Dashboard/         → Visão geral: saldo, tendências, cash flow
│   ├── Accounts/          → CRUD de contas bancárias
│   ├── Transactions/      → Receitas, despesas, transferências
│   ├── Portfolio/         → Investimentos, compra/venda, alocação, dividendos
│   ├── Watchlist/         → Lista de observação com notícias
│   ├── AssetDetail/       → Detalhes de um ativo (gráfico, transações)
│   └── Settings/          → Moeda, tema (claro/escuro/sistema)
├── Models/                → Modelos SwiftData
├── Services/              → API Yahoo Finance
├── ContentView.swift      → TabView principal (4 tabs)
└── PatrimonialApp.swift   → Entry point (@main)
```

---

## Modelos de Dados (SwiftData)

### Account
| Campo | Tipo | Descrição |
|-------|------|-----------|
| `name` | String | Nome da conta |
| `type` | AccountType | checking, savings, creditCard, brokerage |
| `currency` | String | EUR, USD, GBP |
| `icon` | String | SF Symbol |
| `colorHex` | String | Cor em hex |
| `balance` | Decimal | Calculado a partir das transações |

**Relações:** `outgoingTransactions` (cascade), `incomingTransactions` (nullify)

### FinancialTransaction
| Campo | Tipo | Descrição |
|-------|------|-----------|
| `type` | TransactionType | expense, income, transfer, assetPurchase, assetSale, dividend |
| `amount` | Decimal | Valor da transação |
| `date` | Date | Data |
| `category` | String | Categoria (ex: alimentação, salário) |
| `note` | String | Nota opcional |
| `quantity` | Decimal? | Quantidade (investimentos) |
| `pricePerUnit` | Decimal? | Preço por unidade |
| `fees` | Decimal? | Comissões |

**Relações:** `sourceAccount`, `destinationAccount`, `position`

### Asset
| Campo | Tipo | Descrição |
|-------|------|-----------|
| `ticker` | String | Símbolo (ex: AAPL, VWCE.DE) |
| `name` | String | Nome completo |
| `assetType` | AssetType | stock, etf, crypto, other |
| `exchange` | String | Bolsa |
| `currency` | String | Moeda de cotação |

**Relações:** `positions` (cascade), `priceSnapshots` (cascade)

### Position
| Campo | Tipo | Descrição |
|-------|------|-----------|
| `sharesHeld` | Decimal | Ações detidas (calculado) |
| `averageCost` | Decimal | Preço médio (calculado) |
| `totalInvested` | Decimal | Total investido (calculado) |
| `totalDividends` | Decimal | Dividendos recebidos (calculado) |

**Relações:** `asset`, `account`, `transactions` (cascade)

### WatchlistItem
| Campo | Tipo | Descrição |
|-------|------|-----------|
| `ticker` | String | Símbolo |
| `name` | String | Nome do ativo |
| `assetTypeRaw` | String | Tipo de ativo |
| `exchange` | String | Bolsa |
| `dateAdded` | Date | Data de adição |

### PriceSnapshot
Cache local de preços com propriedade `isStale` (>60s).

---

## Serviço de Dados de Mercado

**Protocolo:** `MarketDataService`

**Implementação:** `YahooFinanceService` (ficheiro `FinnhubService.swift`)

| Método | Endpoint Yahoo Finance | Descrição |
|--------|----------------------|-----------|
| `search(query:)` | `/v1/finance/search` | Pesquisa de tickers |
| `quote(for:)` | `/v8/finance/chart/{ticker}` | Cotação atual |
| `chartData(for:range:)` | `/v8/finance/chart/{ticker}` | Dados históricos para gráficos |
| `dividendHistory(for:)` | `/v8/finance/chart/{ticker}?events=div` | Histórico de dividendos |
| `news(for:)` | `/v1/finance/search` (newsCount=15) | Notícias do ativo |

**Conversão cambial:** Pares como `USDEUR=X` são obtidos como quotes normais.

---

## Design System

### Paleta de Cores (`Color+Theme.swift`)

| Cor | Light | Dark | Uso |
|-----|-------|------|-----|
| `screenBackground` | #F0F2F7 | #13131E | Fundo geral |
| `cardBackground` | #FFFFFF | #1C1C2E | Fundo de cards |
| `primaryAction` | #FF6B6B | #FF7B7B | Botões, ações, tint |
| `secondaryAccent` | #4ECDC4 | #5AD8CE | Gráficos de tendência |
| `gainGreen` | #4ECDC4 | #5AD8CE | Valores positivos |
| `lossRed` | #E74C57 | #FF5A68 | Valores negativos |
| `textPrimary` | #2B2D42 | #E8EAF0 | Texto principal |
| `subtleText` | #6B6D83 | #8B8DA0 | Texto secundário |

### Tipografia (`Font+Theme.swift`)

| Nome | Estilo | Uso |
|------|--------|-----|
| `.heroValue` | Large Title, Rounded, Bold | Saldos grandes |
| `.sectionTitle` | Title3, Semibold | Títulos de secção |
| `.cardTitle` | Headline, Semibold | Título dentro de cards |
| `.cardBody` | Subheadline | Corpo dentro de cards |
| `.monoValue` | Body, Monospaced, Medium | Valores numéricos |

### Componentes

- **Card** — Container com padding, fundo `cardBackground`, cantos arredondados (12px), borda subtil em modo claro
- **PrimaryButton** — Botão largo com fundo `primaryAction` e texto branco
- **EmptyState** — Ícone + título + mensagem + botão opcional (usa `ContentUnavailableView`)

---

## Navegação

A app usa `TabView` com 4 tabs:

1. **Dashboard** (`chart.pie.fill`) — Saldo total, gráfico de tendência, cash flow mensal, contas
2. **Movimentos** (`arrow.left.arrow.right`) — Lista de contas, transações, formulários de receita/despesa/transferência
3. **Portfolio** (`chart.line.uptrend.xyaxis`) — Posições de investimento, gráfico combinado, alocação (donut chart), dividendos, compra/venda
4. **Watchlist** (`star.fill`) — Lista de observação com sparklines, detalhes com gráfico interativo e notícias

### Gráficos Interativos
Todos os gráficos usam **Swift Charts** com:
- `LineMark` + `AreaMark` com gradiente
- `RuleMark` + `PointMark` para scrubbing
- `chartOverlay` com `DragGesture` para interação
- Seletor de período (1D, 1S, 1M, 3M, 6M, YTD, 1A, Max)

---

## Padrões Utilizados

- **@Observable ViewModels** — `PortfolioViewModel`, `DashboardViewModel`, `AccountsViewModel`, `TransactionsViewModel`
- **@Query** — Acesso direto ao SwiftData nas views
- **@AppStorage** — Persistência de preferências (moeda, tema)
- **TaskGroup** — Carregamento paralelo de múltiplas cotações
- **async/await** — Todas as chamadas de rede são assíncronas
- **Localização** — `Localizable.xcstrings` com suporte PT/EN

---

## Definições

Disponíveis em **Settings** (ícone de engrenagem no Dashboard):
- **Moeda principal** — EUR, USD, GBP
- **Tema** — Sistema, Claro, Escuro
