function P2D(case::Case, yt::Array{Float64}, t::Float64; jacobi::String)
    variables = P2D_variables(case, yt, t)
    param = case.param
    mesh_np = case.mesh["negative particle"]
    mesh_pp = case.mesh["positive particle"]
    mesh_el = case.mesh["electrolyte"]
    mesh_ne = case.mesh["negative electrode"]
    mesh_pe = case.mesh["positive electrode"]
    if jacobi == "constant" && param.NE.M_d != [] # no need to update M and K
        M_ne_d = param.NE.M_d
        K_ne_d = param.NE.K_d
        M_pe_d = param.PE.M_d
        K_pe_d = param.PE.K_d
        M_ne_p = param.NE.M_p
        K_ne_p = param.NE.K_p
        M_pe_p = param.PE.M_p
        K_pe_p = param.PE.K_p
    else
        M_ne_d, K_ne_d = ElectrodeDiffusion(param.NE, mesh_np, mesh_np.nlen)
        M_pe_d, K_pe_d = ElectrodeDiffusion(param.PE, mesh_pp, mesh_pp.nlen)
        M_ne_p, K_ne_p = ElectrodePotential(param.NE, mesh_ne, mesh_ne.nlen)
        M_pe_p, K_pe_p = ElectrodePotential(param.PE, mesh_pe, mesh_pe.nlen) 
        M_ne_d = M_ne_d .* param.scale.ts_n
        M_pe_d = M_pe_d .* param.scale.ts_p    
    end
    M_el_d, K_el_d = ElectrolyteDiffusion(param, mesh_el, mesh_el.nlen, variables)   
    M_el_p, K_el_p = ElectrolytePotential(param, mesh_el, mesh_el.nlen, variables) 
    M_el_d = M_el_d .* param.scale.te 

    # # the following part seems not to affect the result, need to recheck later
    # # add interface boundary condition 
    # xloc = [1.0, 0, 1.0, 0]
    # v = [case.opt.Nn, case.opt.Nn + 1, case.opt.Nn + case.opt.Ns, case.opt.Nn + case.opt.Ns + 1]
    # _, dNidx = ShapeFunction1D(mesh_el.element, mesh_el.type, mesh_el.node, xloc, v)  
    # v_ns = case.mesh["negative electrode"].nlen
    # v_sp = case.mesh["negative electrode"].nlen + case.mesh["separator"].nlen - 1
    # M_el_d[v_ns, :] .= 0
    # M_el_d[v_sp, :] .= 0
    # K_el_d[v_ns, :] .= 0
    # K_el_d[v_sp, :] .= 0
    # ce = param.EL.ce0 # need to modify later
    # T = 298.0
    # De_eff =  param.EL.De(ce) * Arrhenius(param.EL.Eac_D, T)
    # K_el_d[v_ns, mesh_el.element[v[1],:]] .+= dNidx[1,:] .* De_eff
    # K_el_d[v_ns, mesh_el.element[v[2],:]] .+= - dNidx[2,:] .* De_eff
    # K_el_d[v_sp, mesh_el.element[v[3],:]] .+= dNidx[3,:] .* De_eff
    # K_el_d[v_sp, mesh_el.element[v[4],:]] .+= - dNidx[4,:] .* De_eff
    # F[mesh_np.nlen + mesh_pp.nlen + v_ns] = 0
    # F[mesh_np.nlen + mesh_pp.nlen + v_sp] = 0

    # # need to update source term
    K_pot = blockdiag(K_ne_p, K_pe_p, K_el_p)
    phi_new, variables = P2D_potentials(case, yt, t, K_pot, variables)
    F = [P2D_mass_BC(case, variables); phi_new]
    n_con = mesh_ne.nlen + mesh_pe.nlen + mesh_el.nlen
    M = blockdiag(M_ne_d, M_pe_d, M_el_d, M_ne_p, M_pe_p, M_el_p)
    K = blockdiag(K_ne_d, K_pe_d, K_el_d, - sparse(1.0I, n_con, n_con))
    return M, K, F, variables
end

function P2D_mass_BC(case::Case, variables::Dict{String, Union{Array{Float64},Float64}})
    param = case.param

    # electrode particle diffusion source term
    j_n = variables["negative electrode interfacial current density"]
    j_p = variables["positive electrode interfacial current density"]
    flux_np = zeros(Float64, case.mesh["negative particle"].nlen, 1)
    v_np_surf = case.index["negative particle surface lithium concentration"]
    flux_np[v_np_surf] = - j_n * param.NE.rs^2
    flux_pp = zeros(Float64, case.mesh["positive particle"].nlen, 1)
    v_pp_surf = case.index["positive particle surface lithium concentration"] .- case.mesh["negative particle"].nlen
    flux_pp[v_pp_surf] = - j_p * param.PE.rs^2

    # electrolyte diffusion source term
    mesh_el = case.mesh["electrolyte"]
    n_sp_gs = case.opt.Ns * mesh_el.gs.order
    j_n_gs = variables["negative electrode interfacial current at Gauss point"]
    j_p_gs = variables["positive electrode interfacial current at Gauss point"]
    aj_el_gs = [j_n_gs * param.NE.as ; zeros(n_sp_gs, 1); j_p_gs * param.PE.as] 
    coeff_el = mesh_el.gs.weight .* mesh_el.gs.detJ .* aj_el_gs .* (1 - param.EL.tplus)
    Vi_el = mesh_el.element[mesh_el.gs.ele,:]
    flux_el = Assemble1D(Vi_el, mesh_el.gs.Ni, coeff_el, mesh_el.nlen)

    # assemble all fluxes
    return [flux_np; flux_pp; flux_el]
end

function P2D_charge_BC(case::Case, variables::Dict{String, Union{Array{Float64},Float64}})
    param = case.param
    t = variables["time"]
    I_app = case.opt.Current(t) / case.param_dim.cell.area / param.scale.I_typ
    mesh_el = case.mesh["electrolyte"]
    Vi_el = mesh_el.element[mesh_el.gs.ele,:]
    n_sp_gs = case.opt.Ns * mesh_el.gs.order
    j_n_gs = variables["negative electrode interfacial current at Gauss point"]
    j_p_gs = variables["positive electrode interfacial current at Gauss point"]
    aj_el_gs = [j_n_gs * param.NE.as ; zeros(n_sp_gs, 1); j_p_gs * param.PE.as] 

    # negative electrode charge source term
    mesh_ne = case.mesh["negative electrode"]
    coeff_ne = mesh_ne.gs.weight .* mesh_ne.gs.detJ * param.NE.as .* j_n_gs
    Vi_ne = mesh_ne.element[mesh_ne.gs.ele,:]
    flux_ne = Assemble1D(Vi_ne, mesh_ne.gs.Ni, coeff_ne, mesh_ne.nlen)
    flux_ne[1] += I_app # this item is wiped and not used

    # positive electrode charge source term
    mesh_pe = case.mesh["positive electrode"]
    coeff_pe = mesh_pe.gs.weight .* mesh_pe.gs.detJ * param.PE.as .* j_p_gs
    Vi_pe = mesh_pe.element[mesh_pe.gs.ele,:]
    flux_pe = Assemble1D(Vi_pe, mesh_pe.gs.Ni, coeff_pe, mesh_pe.nlen)
    flux_pe[end] += - I_app    # this item is wiped and not used

    # electrolyte charge source term
    coeff_elc = mesh_el.gs.weight .* mesh_el.gs.detJ .* aj_el_gs
    flux_elc = Assemble1D(Vi_el, mesh_el.gs.Ni, coeff_elc, mesh_el.nlen)

    ce = variables["electrolyte lithium concentration"]
    ce_gs = sum(mesh_el.gs.Ni .* ce[mesh_el.element[mesh_el.gs.ele,:]], dims=2)
    dcedx_gs = sum(mesh_el.gs.dNidx .* ce[mesh_el.element[mesh_el.gs.ele,:]], dims=2)
    T = variables["temperature"]
    kappa_D_eff = param.EL.kappa(ce_gs) .* mesh_el.gs.weight .* mesh_el.gs.detJ
    tau_ne = param.NE.eps ^ param.NE.brugg * ones(size(j_n_gs))
    tau_pe = param.PE.eps ^ param.PE.brugg * ones(size(j_p_gs))
    tau_sp = param.SP.eps ^ param.SP.brugg * ones(n_sp_gs, 1)
    tau_el = [tau_ne; tau_sp; tau_pe]
    kappa_D_eff .*= 2 * T * (1 - param.EL.tplus) .* param.EL.dlnf_dlnc(ce_gs) .* tau_el ./ ce_gs .* dcedx_gs
    flux_elc += Assemble1D(Vi_el, mesh_el.gs.dNidx, kappa_D_eff, mesh_el.nlen)
    # assemble all fluxes
    return flux_ne, flux_pe, flux_elc
end

function P2D_potentials(case::Case, yt::Array{Float64}, t::Float64, K_pot::SparseArrays.SparseMatrixCSC{Float64, Int64}, variables::Dict{String, Union{Array{Float64},Float64}})
    iter_max = 100;
    rel_tol = 1e-6
    penalty = 10000
    mesh_np = case.mesh["negative particle"]
    mesh_pp = case.mesh["positive particle"]
    mesh_el = case.mesh["electrolyte"]
    mesh_ne = case.mesh["negative electrode"]
    mesh_pe = case.mesh["positive electrode"]
    
    # direct enforcement
    K_pot[1 ,:] .= 0.0
    K_pot[1, 1] = - 1.0
    K_pot[mesh_ne.nlen + 1,:] .= 0.0
    K_pot[mesh_ne.nlen + 1, mesh_ne.nlen + 1] = - 1.0
    K_pot[mesh_ne.nlen + mesh_pe.nlen + 1,:] .= 0.0
    K_pot[mesh_ne.nlen + mesh_pe.nlen + 1, mesh_ne.nlen + mesh_pe.nlen + 1] = - 1.0

    # # # penalty enforcement
    # K_pot[1 ,:] .= 0.0
    # K_pot[1, 1] = - 1.0
    # K_pot[mesh_ne.nlen + 1,:] .= 0.0
    # K_pot[mesh_ne.nlen + 1, mesh_ne.nlen + 1] += - penalty
    # K_pot[mesh_ne.nlen + mesh_pe.nlen + 1, mesh_ne.nlen + mesh_pe.nlen + 1] += - penalty


    I_app = case.opt.Current(t) / case.param_dim.cell.area / case.param.scale.I_typ
    j0_n_gs = variables["negative electrode exchange current density at Gauss point"]
    j0_p_gs = variables["positive electrode exchange current density at Gauss point"]
    u_n_gs = variables["negative electrode open circuit potential at Gauss point"]
    u_p_gs = variables["positive electrode open circuit potential at Gauss point"] 

    gs_ne = mesh_ne.gs
    gs_pe = mesh_pe.gs
    element_ne = mesh_ne.element
    element_pe = mesh_pe.element
    for i = 1:iter_max
    # # relative potential        
        j_n_gs_old = variables["negative electrode interfacial current at Gauss point"]
        j_p_gs_old = variables["positive electrode interfacial current at Gauss point"]
        j_gs_old = [j_n_gs_old; j_p_gs_old]
        flux_ne, flux_pe, flux_elc = P2D_charge_BC(case, variables)  

        # direct enforcement
        flux_ne[1] = 0.0
        flux_pe[1] = u_p_gs[1] # this is reference value and will be corrected by iterations
        flux_elc[1] = 0.0

        # # # penalty enforcement
        # flux_ne[1] = 0.0
        # flux_pe[1] += 0 #u_p_gs[1] * penalty # this is reference value and will be corrected by iterations
        # flux_elc[1] += 0.0

        F_pot = [flux_ne; flux_pe; flux_elc]
        phi_new_rel = - K_pot \ F_pot
        phis_n_rel = phi_new_rel[1:mesh_ne.nlen]
        phis_p_rel = phi_new_rel[mesh_ne.nlen + 1 : mesh_ne.nlen + mesh_pe.nlen]
        phie_rel = phi_new_rel[mesh_ne.nlen + mesh_pe.nlen + 1 : end]
        phie_n_rel = phie_rel[1 : mesh_ne.nlen]
        phie_p_rel = phie_rel[end - mesh_pe.nlen + 1 : end]
        phis_n_gs_rel = sum(gs_ne.Ni .* phis_n_rel[element_ne[gs_ne.ele,:]], dims=2)
        phis_p_gs_rel = sum(gs_pe.Ni .* phis_p_rel[element_pe[gs_pe.ele,:]], dims=2)
        phie_n_gs_rel = sum(gs_ne.Ni .* phie_n_rel[element_ne[gs_ne.ele,:]], dims=2)
        phie_p_gs_rel = sum(gs_pe.Ni .* phie_p_rel[element_pe[gs_pe.ele,:]], dims=2)
        eta_n_gs_rel = phis_n_gs_rel - phie_n_gs_rel - u_n_gs
        eta_p_gs_rel = phis_p_gs_rel - phie_p_gs_rel - u_p_gs
    # # reference potential  
        I_np = IntV(case.param.NE.as .* j0_n_gs .* exp.(0.5 * eta_n_gs_rel), mesh_ne)
        I_nn = IntV(case.param.NE.as .* j0_n_gs .* exp.(-0.5 * eta_n_gs_rel), mesh_ne)
        I_pp = IntV(case.param.PE.as .* j0_p_gs .* exp.(0.5 * eta_p_gs_rel), mesh_pe)
        I_pn = IntV(case.param.PE.as .* j0_p_gs .* exp.(-0.5 * eta_p_gs_rel), mesh_pe)
        Ve = - 2.0 * log((-I_app + sqrt(4.0 * I_np * I_nn + I_app^2.0))/ 2.0 / I_np)
        Vp = 2.0 * log((I_app + sqrt(4.0 * I_pp * I_pn + I_app^2.0)) / 2.0 / I_pp) + Ve

        # solve electrode & electrolyte potentials
        phi_new = [phis_n_rel; phis_p_rel .+ Vp; phie_rel .+ Ve]
        yt_new = [yt[1:mesh_np.nlen + mesh_pp.nlen + mesh_el.nlen,1]; phi_new]
        variables = P2D_variables(case, yt_new, t)
        j_n_gs_new = variables["negative electrode interfacial current at Gauss point"]
        j_p_gs_new = variables["positive electrode interfacial current at Gauss point"]
        j_gs_new = [j_n_gs_new; j_p_gs_new]
        error_j = norm(j_gs_new - j_gs_old) / norm(j_gs_old)
        # error_phi =  norm(phi_new - phi_old) / norm(phi_old) 
        if  error_j < rel_tol # && error_phi < rel_tol # the error of phi is much smaller than that of j
            return phi_new, variables
        elseif i == iter_max
            print("maximum iteration mumber has been reached for solving potential equations \n")
            return phi_new, variables
        end
    end
end

function P2D_variables(case::Case, yt::Array{Float64}, t::Float64)
    param = case.param
    variables = StandardVariables(case, 1)
    var_list = collect(keys(case.index))
    for i in var_list
        variables[i] = yt[case.index[i]] # hcat converts vector to matrix
    end
    if "temperature" in var_list
        T = yt[case.index["temperature"]]
    else
        T = case.param.cell.T0
    end
    gs_ne = case.mesh["negative electrode"].gs
    gs_pe = case.mesh["positive electrode"].gs
    gs_sp = case.mesh["separator"].gs
    element_ne = case.mesh["negative electrode"].element
    element_pe = case.mesh["positive electrode"].element
    element_sp = case.mesh["separator"].element

    csn_surf = variables["negative particle surface lithium concentration"]
    csp_surf = variables["positive particle surface lithium concentration"]
    phis_n = variables["negative electrode potential"]
    phis_p = variables["positive electrode potential"]
    phie_n = variables["electrolyte potential in negative electrode"]
    phie_p = variables["electrolyte potential in positive electrode"]
    ce_n = variables["electrolyte lithium concentration in negative electrode"]
    ce_p = variables["electrolyte lithium concentration in positive electrode"]
    ce_sp = variables["electrolyte lithium concentration in separator"]
    u_n = param.NE.U(csn_surf)
    u_p = param.PE.U(csp_surf)
    eta_p = phis_p - phie_p - u_p
    eta_n = phis_n - phie_n - u_n
    j0_n =  param.NE.k * Arrhenius(param.NE.Eac_k, T) .* abs.(csn_surf .* (1.0 .- csn_surf) .* ce_n) .^ 0.5
    j0_p =  param.PE.k * Arrhenius(param.PE.Eac_k, T) .* abs.(csp_surf .* (1.0 .- csp_surf) .* ce_p) .^ 0.5
    j_n = j0_n .* sinh.(0.5 .* eta_n) * 2.0
    j_p = j0_p .* sinh.(0.5 .* eta_p) * 2.0

    csn_surf_gs = sum(gs_ne.Ni .* csn_surf[element_ne[gs_ne.ele,:]], dims=2)
    csp_surf_gs = sum(gs_pe.Ni .* csp_surf[element_pe[gs_pe.ele,:]], dims=2)
    phis_n_gs = sum(gs_ne.Ni .* phis_n[element_ne[gs_ne.ele,:]], dims=2)
    phis_p_gs = sum(gs_pe.Ni .* phis_p[element_pe[gs_pe.ele,:]], dims=2)
    phie_n_gs = sum(gs_ne.Ni .* phie_n[element_ne[gs_ne.ele,:]], dims=2)
    phie_p_gs = sum(gs_pe.Ni .* phie_p[element_pe[gs_pe.ele,:]], dims=2)
    ce_n_gs = sum(gs_ne.Ni .* ce_n[element_ne[gs_ne.ele,:]], dims=2)
    ce_p_gs = sum(gs_pe.Ni .* ce_p[element_pe[gs_pe.ele,:]], dims=2)
    ce_sp_gs = sum(gs_sp.Ni .* ce_sp[element_sp[gs_sp.ele, :]], dims = 2)
    u_n_gs = param.NE.U(csn_surf_gs)
    u_p_gs = param.PE.U(csp_surf_gs)
    eta_p_gs = phis_p_gs - phie_p_gs - u_p_gs
    eta_n_gs = phis_n_gs - phie_n_gs - u_n_gs
    j0_n_gs =  param.NE.k * Arrhenius(param.NE.Eac_k, T) .* abs.(csn_surf_gs .* (1.0 .- csn_surf_gs) .* ce_n_gs) .^ 0.5
    j0_p_gs =  param.PE.k * Arrhenius(param.PE.Eac_k, T) .* abs.(csp_surf_gs .* (1.0 .- csp_surf_gs) .* ce_p_gs) .^ 0.5
    j_n_gs = j0_n_gs .* sinh.(0.5 * eta_n_gs) * 2.0
    j_p_gs = j0_p_gs .* sinh.(0.5 * eta_p_gs) * 2.0

    variables["negative electrode interfacial current density"] = j_n
    variables["positive electrode interfacial current density"] = j_p
    variables["negative electrode exchange current density"] = j0_n
    variables["positive electrode exchange current density"] = j0_p
    variables["negative electrode open circuit potential"] = u_n
    variables["positive electrode open circuit potential"] = u_p
    variables["negative electrode overpotential"] = eta_n
    variables["positive electrode overpotential"] = eta_p    
    variables["negative electrode interfacial current at Gauss point"] = j_n_gs
    variables["positive electrode interfacial current at Gauss point"] = j_p_gs
    variables["negative electrode exchange current density at Gauss point"] = j0_n_gs
    variables["positive electrode exchange current density at Gauss point"] = j0_p_gs
    variables["negative electrode open circuit potential at Gauss point"] = u_n_gs
    variables["positive electrode open circuit potential at Gauss point"] = u_p_gs
    variables["negative electrode overpotential at Gauss point"] = eta_n_gs
    variables["positive electrode overpotential at Gauss point"] = eta_p_gs
    variables["electrolyte lithium concentration at negative electrode Gauss point"] = ce_n_gs
    variables["electrolyte lithium concentration at positive electrode Gauss point"] = ce_p_gs
    variables["electrolyte lithium concentration at separator Gauss point"] = ce_sp_gs
    variables["time"] = t
    variables["temperature"] = T
    variables["cell voltage"] = phis_p[end] - phis_n[1]
    variables["cell current"] = case.opt.Current(t) / case.param_dim.cell.I1C
    return variables
end
