package shop

import (
	"context"
	"net/url"
	"sort"
	"strconv"
	"strings"

	"github.com/mutcherlarahulkumar/pointy/pointy-be/internal/domain"
)

// Demo is a small built-in catalogue of travel things, used when no
// Channel3 key is set, so anyone running Pointy (judges included) can try
// the shopping agent. Prices are in rupees; links open a search at the shop.
type Demo struct{}

type demoItem struct {
	id, title, brand, shop, tags string
	rupees, wasRupees            int64
}

var demoCatalogue = []demoItem{
	{"d-sun50", "Sunscreen SPF 50 PA++++, 100 ml", "Neutrogena", "amazon.in", "sunscreen sunblock spf beach sun lotion", 699, 850},
	{"d-sun30", "Matte sunscreen gel SPF 30, 50 g", "Lakme", "nykaa.com", "sunscreen sunblock spf gel sun", 399, 0},
	{"d-sunfam", "Family pack sunscreen lotion SPF 50, 2 x 200 ml", "Nivea", "flipkart.com", "sunscreen sunblock spf beach family pack", 1149, 1400},
	{"d-spk", "Waterproof Bluetooth speaker, 12 h battery", "boAt", "amazon.in", "speaker bluetooth music party beach waterproof", 1799, 2990},
	{"d-spk2", "Portable party speaker with lights", "JBL", "flipkart.com", "speaker bluetooth music party", 4999, 5999},
	{"d-pouch", "Waterproof phone pouch, pack of 3", "Generic", "amazon.in", "waterproof phone pouch beach rain dry bag", 449, 699},
	{"d-dry", "20 L dry bag for boats and beaches", "Decathlon", "decathlon.in", "dry bag waterproof boat beach kayak", 899, 0},
	{"d-towel", "Quick-dry beach towels, pack of 4", "Bombay Dyeing", "amazon.in", "towel towels beach quick dry", 1299, 1699},
	{"d-snorkel", "Snorkel mask and tube set", "Decathlon", "decathlon.in", "snorkel snorkelling mask diving beach sea", 1499, 0},
	{"d-cards", "UNO and playing cards travel set", "Mattel", "amazon.in", "cards uno games party travel", 349, 0},
	{"d-ice", "Insulated ice box cooler, 25 L", "Milton", "flipkart.com", "cooler ice box drinks beer picnic", 2199, 2799},
	{"d-tent", "4-person camping tent, waterproof", "Decathlon", "decathlon.in", "tent camping camp trek hike", 4999, 5999},
	{"d-torch", "Rechargeable LED torch, pack of 2", "Wipro", "amazon.in", "torch flashlight light camping trek", 799, 999},
	{"d-first", "Travel first-aid kit, 70 pieces", "Dr Trust", "amazon.in", "first aid medical kit medicine travel", 599, 0},
	{"d-mosq", "Mosquito repellent roll-on, pack of 4", "Odomos", "nykaa.com", "mosquito repellent bug insect", 320, 0},
	{"d-rain", "Rain ponchos, pack of 4", "Generic", "amazon.in", "rain poncho raincoat monsoon trek", 599, 799},
	{"d-power", "20,000 mAh power bank, fast charge", "Mi", "amazon.in", "power bank charger battery phone", 1999, 2499},
	{"d-hat", "Sun hats, pack of 2", "Decathlon", "decathlon.in", "hat cap sun beach", 699, 0},
	{"d-glass", "Polarised sunglasses", "Fastrack", "myntra.com", "sunglasses shades sun beach", 1299, 1599},
	{"d-snack", "Trail mix and snack box, 1 kg", "Happilo", "bigbasket.com", "snacks food trail mix nuts road trip", 649, 0},
}

var stopWords = map[string]bool{"for": true, "the": true, "and": true, "our": true, "with": true, "you": true, "all": true, "some": true, "trip": true, "group": true, "need": true, "want": true}

// Search finds the catalogue items that share the most words with the
// query, cheaper first.
func (Demo) Search(_ context.Context, query string, maxPaise domain.Paise, limit int) ([]domain.ShopItem, error) {
	words := strings.Fields(strings.ToLower(query))
	type hit struct {
		it    demoItem
		score int
	}
	var hits []hit
	for _, it := range demoCatalogue {
		hay := " " + strings.ToLower(it.title+" "+it.tags+" "+it.brand) + " "
		score := 0
		for _, w := range words {
			w = strings.Trim(w, ".,!?")
			if len(w) < 3 || stopWords[w] {
				continue
			}
			if strings.Contains(hay, " "+w) || strings.Contains(hay, " "+strings.TrimSuffix(w, "s")+" ") {
				score++
			}
		}
		if score == 0 || (maxPaise > 0 && domain.Rupees(it.rupees) > maxPaise) {
			continue
		}
		hits = append(hits, hit{it, score})
	}
	sort.SliceStable(hits, func(i, j int) bool {
		if hits[i].score != hits[j].score {
			return hits[i].score > hits[j].score
		}
		return hits[i].it.rupees < hits[j].it.rupees
	})
	var out []domain.ShopItem
	for _, h := range hits {
		// Only the closest matches: "speaker for the beach" should not
		// bring every beach thing.
		if len(out) == limit || h.score < hits[0].score {
			break
		}
		it := h.it
		si := domain.ShopItem{ID: it.id, Title: it.title, Brand: it.brand, Merchant: it.shop,
			BuyURL: "https://www." + it.shop + "/search?q=" + url.QueryEscape(it.title), Price: domain.Rupees(it.rupees), ListPrice: "₹" + strconv.FormatInt(it.rupees, 10)}
		if it.wasRupees > 0 {
			si.WasPrice = domain.Rupees(it.wasRupees)
		}
		out = append(out, si)
	}
	return out, nil
}
