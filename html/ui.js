let currentBet = 5; // Default-Bet

window.addEventListener("message", function (event) {
    const data = event.data;
    if (!data || !data.action) return;

    const container     = document.getElementById("bj-container");
    const dealerCardsEl = document.getElementById("dealer-cards");
    const dealerValueEl = document.getElementById("dealer-value");
    const playerCardsEl = document.getElementById("player-cards");
    const playerValueEl = document.getElementById("player-value");
    const playerBetEl   = document.getElementById("player-bet");

    // ----------------------------------------
    // UI SCHLIESSEN
    // ----------------------------------------
    if (data.action === "close") {
        container.classList.add("hidden");

        dealerCardsEl.innerHTML   = "";
        playerCardsEl.innerHTML   = "";
        dealerValueEl.textContent = "";
        playerValueEl.textContent = "";
        playerBetEl.textContent   = "";

        return;
    }

    // ----------------------------------------
    // UI UPDATE
    // ----------------------------------------
    if (data.action === "update") {

        // Weder Runde noch Einsatzphase → UI zu
        if (!data.inRound && !data.showUI) {
            container.classList.add("hidden");
            return;
        }

        // UI anzeigen
        container.classList.remove("hidden");

        // Dealer-Karten
        dealerCardsEl.innerHTML = "";
        if (Array.isArray(data.dealerHand)) {
            data.dealerHand.forEach((card, idx) => {
                const div = document.createElement("div");
                div.classList.add("card");

                let displayCard = card;
                if (!data.revealDealer && idx === 1) {
                    displayCard = "??";
                }

                if (displayCard.includes("♥") || displayCard.includes("♦")) {
                    div.classList.add("red");
                }

                div.textContent = displayCard;
                dealerCardsEl.appendChild(div);
            });
        }

        dealerValueEl.textContent =
            (data.revealDealer && data.dealerValue != null)
                ? "Wert: " + data.dealerValue
                : "Wert: ?";

        // Spieler-Karten
        playerCardsEl.innerHTML = "";
        if (Array.isArray(data.playerHand)) {
            data.playerHand.forEach(card => {
                const div = document.createElement("div");
                div.classList.add("card");

                if (card.includes("♥") || card.includes("♦")) {
                    div.classList.add("red");
                }

                div.textContent = card;
                playerCardsEl.appendChild(div);
            });
        }

        playerValueEl.textContent =
            (data.playerValue != null) ? "Wert: " + data.playerValue : "";

        if (data.playerBet != null) {
            currentBet = data.playerBet;
        }
        playerBetEl.textContent = "Einsatz: $" + currentBet;
    }
});

// Buttons unverändert
function changeBet(amount) {
    currentBet += amount;
    if (currentBet < 1) currentBet = 1;
    if (currentBet > 1000) currentBet = 1000;

    const playerBetEl = document.getElementById("player-bet");
    if (playerBetEl) {
        playerBetEl.textContent = "Einsatz: $" + currentBet;
    }
}

function confirmBet() {
    fetch(`https://${GetParentResourceName()}/setBet`, {
        method: "POST",
        headers: { "Content-Type": "application/json; charset=UTF-8" },
        body: JSON.stringify({ bet: currentBet })
    }).catch((e) => {
        console.log("setBet error", e);
    });
}
