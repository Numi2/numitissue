NEURON {
    SUFFIX phase4_pas
    NONSPECIFIC_CURRENT i
    RANGE g, e
}

PARAMETER {
    g = 0.001 (S/cm2)
    e = -65 (mV)
}

ASSIGNED {
    v (mV)
    i (mA/cm2)
}

BREAKPOINT {
    i = g * (v - e)
}
