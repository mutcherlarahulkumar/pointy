package httpapi_test

import (
	"sync"
	"testing"
)

// Reading a trip while its budgets change must not race: responses point
// into live state, so they are encoded under the service lock.
func TestReadingWhileWritingDoesNotRace(t *testing.T) {
	srv := testServer(t)
	tok, _ := signUp(t, srv, "Asha", "9876543210")
	st, trip := send(t, srv, tok, "", "POST", "/api/trips", map[string]any{"name": "Goa trip", "place": "Goa",
		"start": "2026-10-12T00:00:00+05:30", "end": "2026-10-16T00:00:00+05:30", "deposit_target_paise": 100000})
	if st != 201 {
		t.Fatalf("trip: %d %v", st, trip)
	}
	id := trip["id"].(string)
	var wg sync.WaitGroup
	for i := 0; i < 20; i++ {
		wg.Add(2)
		go func(i int) {
			defer wg.Done()
			send(t, srv, tok, "", "PUT", "/api/trips/"+id+"/budgets", map[string]int{"food": 100000 + i, "stay": 200000 + i})
		}(i)
		go func() {
			defer wg.Done()
			send(t, srv, tok, "", "GET", "/api/trips/"+id, nil)
		}()
	}
	wg.Wait()
}
