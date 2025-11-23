let currentBet = 5;

const container     = document.getElementById("bj-container");
const betPanel      = document.getElementById("bet-panel");
const roundPanels   = document.getElementById("round-panels");
const betAmountEl   = document.getElementById("bet-amount");
const dealerCardsEl = document.getElementById("dealer-cards");
const dealerValueEl = document.getElementById("dealer-value");
const playerCardsEl = document.getElementById("player-cards");
const playerValueEl = document.getElementById("player-value");
const playerBetEl   = document.getElementById("player-bet");

function clampBet(bet) {
    if (bet < 1) return 1;
    if (bet > 1000) return 1000;
    return bet;
}

function updateBetLabels() {
    const betText = `Aktueller Einsatz: $${currentBet}`;
    if (betAmountEl) betAmountEl.textContent = betText;
    if (playerBetEl) playerBetEl.textContent = `Einsatz: $${currentBet}`;
}

function renderCards(target, cards, revealDealer) {
    target.innerHTML = "";
    if (!Array.isArray(cards)) return;

    cards.forEach((card, idx) => {
        const div = document.createElement("div");
        div.classList.add("card");

        let displayCard = card;
        if (!revealDealer && idx === 1) {
            displayCard = "??";
        }

        if (displayCard.includes("♥") || displayCard.includes("♦")) {
            div.classList.add("red");
        }

        div.textContent = displayCard;
        target.appendChild(div);
    });
}

window.addEventListener("message", function (event) {
    const data = event.data;
    if (!data || !data.action) return;

    if (data.action === "close") {
        container.classList.add("hidden");
        betPanel.classList.add("hidden");
        roundPanels.classList.add("hidden");

        dealerCardsEl.innerHTML = "";
        playerCardsEl.innerHTML = "";
        dealerValueEl.textContent = "";
        playerValueEl.textContent = "";
        playerBetEl.textContent = "";
        return;
    }

    if (data.action === "betLocal") {
        if (typeof data.bet === "number") {
            currentBet = clampBet(Math.floor(data.bet));
            updateBetLabels();
        }
        return;
    }

    if (data.action === "update") {
        const inRound  = data.inRound === true;
        const betPhase = data.betPhase === true && !inRound;
        const shouldShow = inRound || data.showUI === true;

        if (typeof data.playerBet === "number") {
            currentBet = clampBet(Math.floor(data.playerBet));
        }

        if (!shouldShow) {
            container.classList.add("hidden");
            betPanel.classList.add("hidden");
            roundPanels.classList.add("hidden");
            return;
        }

        container.classList.remove("hidden");
        updateBetLabels();

        if (betPhase) {
            betPanel.classList.remove("hidden");
            roundPanels.classList.add("hidden");
            dealerCardsEl.innerHTML = "";
            playerCardsEl.innerHTML = "";
            dealerValueEl.textContent = "";
            playerValueEl.textContent = "";
            return;
        }

        betPanel.classList.add("hidden");
        roundPanels.classList.remove("hidden");

        renderCards(dealerCardsEl, data.dealerHand, data.revealDealer === true);
        renderCards(playerCardsEl, data.playerHand, true);

        dealerValueEl.textContent =
            data.revealDealer === true && typeof data.dealerValue === "number"
                ? `Wert: ${data.dealerValue}`
                : "Wert: ?";

        playerValueEl.textContent =
            typeof data.playerValue === "number" ? `Wert: ${data.playerValue}` : "";

        updateBetLabels();
    }
});
