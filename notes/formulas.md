1. The "Gamma Gravity" Filter ($Y$ vs. GEX)Your $Y$ variable measures movement potential based on ATR. However, high GEX (Gamma Exposure) at a specific strike acts like "market glue," suppressing volatility and pinning the price.The Logic: If $Y$ suggests high movement potential, but GEX at strike $X$ is massive and positive, $Y$ is likely a "false positive." Market makers will hedge against the move, killing the ATR.The Formula:$$\text{Adjusted Potential} = \frac{Y}{1 + \text{GEX}_{\text{normalized}}}$$Utility: If the result is low, don't trade the "breakout." The "speed" ($Y$) you expect will be neutralized by the "gravity" of market maker hedging.

2. The "Ice Cube" Ratio (Charm-Adjusted $K$)Charm measures how much Delta you lose every day as time passes. Your $K$ measures your "Leverage Density."The Logic: If you have a high $K$ (great leverage), but Charm is also high, your "skin in the game" is melting away faster than the stock is moving toward the strike.The Formula:$$\text{Efficiency Decay} = \frac{K}{\text{Charm} \times (\text{Days to Exp})}$$Utility: Use this to screen Short-Dated OTM plays. If the ratio is $< 1$, the time decay (Charm) is eating your leverage ($K$) faster than the stock can realistically close the distance ($X$). It’s a "melting ice cube" trade.


. The "Vanna-Speed" CorrelationVanna measures how Delta changes relative to implied volatility (IV). This is the "hidden engine" of a squeeze.The Logic: When a stock moves toward your strike ($X$) and IV is also rising, Vanna causes Delta to explode. This makes your $K$ (Leverage) accelerate non-linearly.The Formula:$$\text{Convexity Score} = (K \times \text{Vanna}) \times \text{IVR}$$Utility: High IVR + High Vanna + High K = A Volatility Coil. This identifies setups where a small move in spot price creates a massive, disproportionate jump in option value because Delta and IV are working in tandem.

The "Tail-Risk" Reality Check (Volga vs. Skew)Volga measures the sensitivity of Vega to changes in IV. Skew tells you which side of the market is "scared."The Logic: If Skew is heavily tilted toward Puts (common in indices) and Volga is peaking, it means the market is pricing in a "Black Swan" event.The Formula:$$\text{Tail Stress} = \frac{\text{Volga} \times \text{Skew}}{\text{IVP}}$$Utility: Use this to determine if OTM options are "cheap" for a reason. If Tail Stress is high, your $X/Y$ calculation (reachability) is secondary to the fact that the market is paying a massive premium for protection, making the "math" of a standard trade break down.

GoalFormula ComponentInstitutional ContextVerify Breakouts$Y$ + GEXAre market makers "pinning" the price at my strike?Avoid Decay$K$ + CharmIs my leverage melting faster than the price is moving?Spot Squeezes$K$ + VannaWill an IV spike supercharge my Delta?Price Black SwansVolga + SkewIs the "volatility of volatility" too high to justify the entry?


Black-Scholes (BS Baseline): Classic model assuming constant volatility and lognormal stock returns. Used as a baseline for fair value calculation.
SABR (Stochastic Alpha Beta Rho): Calibrates implied volatility to match the market's volatility smile/skew, providing more accurate IV estimates than flat BS assumptions.
Heston Model: Incorporates stochastic volatility with mean-reversion, improving pricing for options where volatility changes over time.
Edge Calculation: (Model Fair Value - Broker Mid) / Broker Mid × 10,000 in basis points. Positive edge indicates the model sees value above the market price (buy signal).
I've added info icons (ℹ️) with hover tooltips next to each term in the "Model vs Market" panel:

Broker Mid: Explains it's the live midpoint between bid/ask prices.
BS Baseline: Describes the Black-Scholes model assumptions.
SABR IV: Details the SABR model's role in volatility calibration.
Heston/SABR Fair Value: Covers the advanced stochastic volatility modeling.