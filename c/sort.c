/* sort.c -- bubble sort of an integer array.  Shows the memory-operand ALU
 * (compares straight against memory), the scaled-index loads gcc uses to walk
 * the array, and a conditional swap.  At -O2 gcc tightens the inner loop and
 * keeps more in registers; at -O0 everything spills to the stack frame -- a
 * good side-by-side for an optimization-level discussion.                    */
static int data[6] = { 5, 2, 9, 1, 7, 3 };

static void bubble(int *a, int n) {
    for (int i = 0; i < n - 1; i++)
        for (int j = 0; j < n - 1 - i; j++)
            if (a[j] > a[j + 1]) {              /* compare two array slots    */
                int t = a[j];                   /* swap                       */
                a[j] = a[j + 1];
                a[j + 1] = t;
            }
}

void run(void) {
    volatile int *out = (int *)0x800;
    bubble(data, 6);
    for (int i = 0; i < 6; i++)
        out[i] = data[i];                       /* sorted: 1 2 3 5 7 9        */
    int s = 0;
    for (int i = 0; i < 6; i++)
        s += data[i];
    out[6] = s;                                 /* 27 (checksum)              */
}
