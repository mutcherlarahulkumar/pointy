package domain

// BudgetCheck says what a payment would do to one category's budget.
type BudgetCheck struct {
	Category      Category `json:"category"`
	Limit         Paise    `json:"limit_paise"`
	Used          Paise    `json:"used_paise"`
	After         Paise    `json:"after_paise"`
	Left          Paise    `json:"left_after_paise"`
	PercentBefore int      `json:"percent_before"`
	PercentAfter  int      `json:"percent_after"`
	Crosses80     bool     `json:"crosses_80"`
	Over100       bool     `json:"over_100"`
	Warn          bool     `json:"warn"`
}

func percent(part, whole Paise) int {
	if whole <= 0 {
		return 0
	}
	return int((int64(part)*200 + int64(whole)) / (2 * int64(whole))) // rounded
}

// CheckBudget warns when a payment takes a budget across 80%, or past 100%.
// A limit of zero means no budget is set.
func CheckBudget(cat Category, limit, used, amount Paise) BudgetCheck {
	b := BudgetCheck{Category: cat, Limit: limit, Used: used, After: used + amount}
	if limit <= 0 {
		return b
	}
	b.Left = limit - b.After
	b.PercentBefore = percent(used, limit)
	b.PercentAfter = percent(b.After, limit)
	b.Crosses80 = used*100 < limit*80 && b.After*100 >= limit*80
	b.Over100 = b.After > limit
	b.Warn = b.Crosses80 || b.Over100
	return b
}
