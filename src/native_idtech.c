// Native replacements specific to id Tech (DOOM 2016); the generic ones are in native.c.
#include "cpu.h"
#include "rt.h"

// ---- idStr comparisons (signed chars; -1 / 0 / 1 like the originals) ----
static inline int32_t str_cmp(const int8_t *a, const int8_t *b) {
    for (;; a++, b++) {
        int c1 = *a, c2 = *b, d = c1 - c2;
        if (d) return d > 0 ? 1 : -1;
        if (!c1) return 0;
    }
}
// ASCII case-insensitive: an upper-case letter on either side is folded before giving up
static inline int32_t str_icmp(const int8_t *a, const int8_t *b) {
    for (;; a++, b++) {
        int c1 = *a, c2 = *b, d = c1 - c2;
        if (d) {
            if ((unsigned)(c1 - 'A') <= 25u) { d += 32; if (!d) goto same; }
            if ((unsigned)(c2 - 'A') <= 25u) { d -= 32; if (!d) goto same; }
            return d > 0 ? 1 : -1;
        }
      same:
        if (!c1) return 0;
    }
}
void N_idStr_Cmp(CPU *c)        { RET((uint32_t)str_cmp(PTR(A0), PTR(A1))); }                 // static Cmp(s1, s2)
void N_idStr_CmpMember(CPU *c)  { RET((uint32_t)str_cmp(PTR(*(uint64_t *)PTR(A0 + 0x10)), PTR(A1))); }   // this->data vs s
void N_idStr_Icmp(CPU *c)       { RET((uint32_t)str_icmp(PTR(A0), PTR(A1))); }                // static Icmp(s1, s2)

