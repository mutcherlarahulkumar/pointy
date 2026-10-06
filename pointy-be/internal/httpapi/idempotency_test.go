package httpapi

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
)

// One signed-in caller sending endless fresh keys cannot grow the replay
// cache without limit.
func TestIdempotencyCacheIsBounded(t *testing.T) {
	s := &server{idem: map[string]*replay{}}
	ok := func(w http.ResponseWriter) { writeJSON(w, http.StatusCreated, map[string]bool{"ok": true}) }
	for i := 0; i < idemMax+500; i++ {
		r := httptest.NewRequest("POST", "/api/alerts/seen", nil)
		r = r.WithContext(context.WithValue(r.Context(), ctxKey{}, "u_1"))
		r.Header.Set("Idempotency-Key", fmt.Sprint(i))
		s.idempotent(httptest.NewRecorder(), r, ok)
	}
	if len(s.idem) > idemMax || len(s.idemList) > idemMax {
		t.Fatalf("cache holds %d answers (%d keys); the limit is %d", len(s.idem), len(s.idemList), idemMax)
	}
}
