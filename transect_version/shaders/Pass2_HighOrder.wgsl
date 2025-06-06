struct Globals {
    width: u32,
    height: u32,
    g: f32,
    half_g: f32,
    dx: f32,
    dy: f32,
    delta: f32,
    useSedTransModel: i32,
};

@group(0) @binding(0) var<uniform> globals: Globals;

@group(0) @binding(1) var txH: texture_2d<f32>;
@group(0) @binding(2) var txU: texture_2d<f32>;
@group(0) @binding(3) var txV: texture_2d<f32>;
@group(0) @binding(4) var txBottom: texture_2d<f32>;
@group(0) @binding(5) var txC: texture_2d<f32>;
@group(0) @binding(6) var txHnear: texture_2d<f32>;

@group(0) @binding(7) var txXFlux: texture_storage_2d<rgba32float, write>;
@group(0) @binding(8) var txYFlux: texture_storage_2d<rgba32float, write>;

@group(0) @binding(9) var txSed_C1: texture_2d<f32>;
@group(0) @binding(10) var txSed_C2: texture_2d<f32>;
@group(0) @binding(11) var txSed_C3: texture_2d<f32>;
@group(0) @binding(12) var txSed_C4: texture_2d<f32>;

@group(0) @binding(13) var txXFlux_Sed: texture_storage_2d<rgba32float, write>;
@group(0) @binding(14) var txYFlux_Sed: texture_storage_2d<rgba32float, write>;

fn NumericalFlux(aplus: f32, aminus: f32, Fplus: f32, Fminus: f32, Udifference: f32) -> f32 {
    if (aplus - aminus != 0.0) {
        return (aplus * Fminus - aminus * Fplus + aplus * aminus * Udifference) / (aplus - aminus);
    } else {
        return 0.0;
    }
}


// ----------------------------------------------------
// HLL_Flux / HLLEM_Flux
//   aplus    = S_R
//   aminus   = S_L
//   Fplus    = F_R = [h⁺u⁺, h⁺u⁺², h⁺u⁺v⁺, h⁺u⁺c⁺]
//   Fminus   = F_L = [h⁻u⁻, h⁻u⁻², h⁻u⁻v⁻, h⁻u⁻c⁻]
//   Uplus    = U_R = [h⁺, h⁺u⁺, h⁺v⁺, h⁺c⁺]
//   Uminus   = U_L = [h⁻, h⁻u⁻, h⁻v⁻, h⁻c⁻]
// ----------------------------------------------------
fn HLL_Flux(
    aplus:    f32,
    aminus:   f32,
    Fplus:    vec4<f32>,
    Fminus:   vec4<f32>,
    Uplus:    vec4<f32>,
    Uminus:   vec4<f32>,
    DU_flag:  i32
) -> vec4<f32> {
    let denom = aplus - aminus;
    if (denom == 0.0) {
        return vec4<f32>(0.0);
    }
    var DU = Uplus - Uminus;  // ΔU
    if (DU_flag == 1) {
        DU.x = 0.0;
    }
    // standard two‐wave HLL:
    //   (S_R F_L - S_L F_R + S_L S_R ΔU) / (S_R - S_L)
    return (aplus * Fminus
          - aminus * Fplus
          + aplus * aminus * DU)
         / denom;
}


fn HLLEM_Flux(
    aplus:    f32,         // S_R
    aminus:   f32,         // S_L
    Fplus:    vec4<f32>,   // F⁺
    Fminus:   vec4<f32>,   // F⁻
    Uplus:    vec4<f32>,   // U⁺
    Uminus:   vec4<f32>,    // U⁻
    DU_flag:  i32          // flag for near dry cells
) -> vec4<f32> {
    // 1) Compute the base HLL flux
    let Fhll = HLL_Flux(aplus, aminus, Fplus, Fminus, Uplus, Uminus, DU_flag);

    // 2) Roe‐average velocity for the contact wave
    var uL: f32 = 0.0;
    if (Uminus.x > 0.0) {
        uL = Fminus.x / Uminus.x;
    }
    var uR: f32 = 0.0;
    if (Uplus.x > 0.0) {
        uR = Fplus.x / Uplus.x;
    }
    let sqrt_hL = sqrt(max(Uminus.x, 0.0));
    let sqrt_hR = sqrt(max(Uplus.x,  0.0));
    let denomR = sqrt_hL + sqrt_hR;
    var uRoe: f32 = 0.0;
    if (denomR > 0.0) {
        uRoe = (sqrt_hL * uL + sqrt_hR * uR) / denomR;
    }

    // 3) Build a simple Roe‐type “linearized” flux
    //    Froe = 0.5*(F⁺ + F⁻) - 0.5*|uRoe|*(U⁺ - U⁻)
    var DU = Uplus - Uminus;
    if (DU_flag == 1) {
        DU.x = 0.0;
    }
    let Froe = 0.5 * (Fplus + Fminus) - 0.5 * abs(uRoe) * DU;

    // 4) Compute a limiter φ that restores the contact
    //    φ = max(0, 1 - max(|S_L|,|S_R|)/(|uRoe|+ε))
    let epsilon: f32 = 1e-6;
    let wavespeed_max = max(abs(aminus), abs(aplus));
    let psi = max(0.0, 1.0 - wavespeed_max / (abs(uRoe) + epsilon));

    // 5) Return HLLEM flux = Fhll + φ*(Froe - Fhll)
    return Fhll + psi * (Froe - Fhll);
}


@compute @workgroup_size(16, 16)
fn main(@builtin(global_invocation_id) id: vec3<u32>) {
    let idx = vec2<i32>(i32(id.x), i32(id.y));
    
    // Handle boundary conditions
    let rightIdx = min(idx + vec2<i32>(1, 0), vec2<i32>(i32(globals.width)-1, i32(globals.height)-1));
   // let upIdx = min(idx + vec2<i32>(0, 1), vec2<i32>(i32(globals.width)-1, i32(globals.height)-1));
    let leftIdx = max(idx + vec2<i32>(-1, 0), vec2<i32>(0, 0));
   // let downIdx = max(idx + vec2<i32>(0, -1), vec2<i32>(0, 0));
    
    // Fetch the necessary data from the input textures
    let h_vec = textureLoad(txHnear, idx, 0);
    var h_here = textureLoad(txH, idx, 0).xy;   // flow depth at top (x) and right (y) side of current cell
    
    var hW_east = textureLoad(txH, rightIdx, 0).w;  // flow depth at left side of east cell
   // var hS_north = textureLoad(txH, upIdx, 0).z;  // flow depth at bottom side of north cell

    var u_here = textureLoad(txU, idx, 0).xy;  // x-direction flow velocity at top (x) and right (y) side of current cell
    var uW_east = textureLoad(txU, rightIdx, 0).w;  // x-direction flow velocity at left side of east cell
   // var uS_north = textureLoad(txU, upIdx, 0).z;  // x-direction flow velocity at bottom side of north cell

   // var v_here = textureLoad(txV, idx, 0).xy;  // y-direction flow velocity at top (x) and right (y) side of current cell
   // var vW_east = textureLoad(txV, rightIdx, 0).w; // y-direction flow velocity at left side of east cell
   // var vS_north = textureLoad(txV, upIdx, 0).z; // y-direction flow velocity at bottom side of north cell

    let cNE = sqrt((globals.g * h_here));  // long wave speed at top (x) and right (y) side of current cell
    let cW = sqrt((globals.g * hW_east));  // long wave speed at left side of east cell
   // let cS = sqrt((globals.g * hS_north));  // long wave speed at bottom side of north cell

    let aplus = max(max(u_here.y + cNE.y, uW_east + cW), 0.0);   // max speed in x-direction
    let aminus = min(min(u_here.y - cNE.y, uW_east - cW), 0.0);     // min speed in x-direction
   // let bplus = max(max(v_here.x + cNE.x, vS_north + cS), 0.0);  // max speed in y-direction 
   // let bminus = min(min(v_here.x - cNE.x, vS_north - cS), 0.0);    // min speed in y-direction

    let c_here = textureLoad(txC, idx, 0).xy;  // concentration at top (x) and right (y) side of current cell
    let cW_east = textureLoad(txC, rightIdx, 0).w;  // concentration at left side of east cell
   // let cS_north = textureLoad(txC, upIdx, 0).z;  // concentration at bottom side of north cell

   // let minH = min(h_vec.w, min(h_vec.z, min(h_vec.y, h_vec.x)));  // minimum water height in the cell and its neighbors
    let minH = min(h_vec.w, h_vec.y);  // minimum water height in the cell and its neighbors

    var DU_flag = 0;
    if (minH <= globals.delta) {  // special treament for near dry cells
        DU_flag = 1;
    }

   // let state_plus_x = vec4<f32>(hW_east, hW_east * uW_east, hW_east * vW_east, hW_east * cW_east); // state at the cell face
   // let state_minus_x = vec4<f32>(h_here.y, h_here.y * u_here.y, h_here.y * v_here.y, h_here.y * c_here.y); // state at the cell face

    let state_plus_x = vec4<f32>(hW_east, hW_east * uW_east, 0.0, hW_east * cW_east); // state at the cell face
    let state_minus_x = vec4<f32>(h_here.y, h_here.y * u_here.y, 0.0, h_here.y * c_here.y); // state at the cell face

    let Fp_x = state_plus_x * uW_east; // F⁺ = [h⁺u⁺, h⁺u⁺², h⁺u⁺v⁺, h⁺u⁺c⁺]
    let Fm_x = state_minus_x * u_here.y; // F⁻ = [h⁻u⁻, h⁻u⁻², h⁻u⁻v⁻, h⁻u⁻c⁻]
    let DU_x = state_plus_x - state_minus_x; // ΔU = [h⁺–h⁻, (h⁺u⁺–h⁻u⁻), (h⁺v⁺–h⁻v⁻), (h⁺c⁺–h⁻c⁻)]

   // let state_plus_y = vec4<f32>(hS_north, hS_north * uS_north, hS_north * vS_north, hS_north * cS_north); // state at the cell face
   // let state_minus_y = vec4<f32>(h_here.x, h_here.x * u_here.x, h_here.x * v_here.x, h_here.x * c_here.x); // state at the cell face

   // let Fp_y = state_plus_y * vS_north; // F⁺ = [h⁺u⁺, h⁺u⁺², h⁺u⁺v⁺, h⁺u⁺c⁺]
   // let Fm_y = state_minus_y * v_here.x; // F⁻ = [h⁻u⁻, h⁻u⁻², h⁻u⁻v⁻, h⁻u⁻c⁻]
   // let DU_y = state_plus_y - state_minus_y; // ΔU = [h⁺–h⁻, (h⁺u⁺–h⁻u⁻), (h⁺v⁺–h⁻v⁻), (h⁺c⁺–h⁻c⁻)]

    // call the vectorized HLL flux
    var xflux = vec4<f32>(0.0);
   // var yflux = vec4<f32>(0.0);

    xflux = HLLEM_Flux(aplus, aminus, Fp_x, Fm_x, state_plus_x, state_minus_x, DU_flag);
   // yflux = HLLEM_Flux(bplus, bminus, Fp_y, Fm_y, state_plus_y, state_minus_y, DU_flag);

    textureStore(txXFlux, idx, xflux);
   // textureStore(txYFlux, idx, yflux);

    let phix = 1.0;
    let phiy = 1.0;
    if(globals.useSedTransModel == 1){
        // Sediment transport code
        let c1_here = textureLoad(txSed_C1, idx, 0).xy;
        let c1W_east = textureLoad(txSed_C1, rightIdx, 0).w;
       // let c1S_north = textureLoad(txSed_C1, upIdx, 0).z;

        let c2_here = textureLoad(txSed_C2, idx, 0).xy;
        let c2W_east = textureLoad(txSed_C2, rightIdx, 0).w;
       // let c2S_north = textureLoad(txSed_C2, upIdx, 0).z;

        let c3_here = textureLoad(txSed_C3, idx, 0).xy;
        let c3W_east = textureLoad(txSed_C3, rightIdx, 0).w;
       // let c3S_north = textureLoad(txSed_C3, upIdx, 0).z;

        let c4_here = textureLoad(txSed_C4, idx, 0).xy;
        let c4W_east = textureLoad(txSed_C4, rightIdx, 0).w;
       // let c4S_north = textureLoad(txSed_C4, upIdx, 0).z;

        let xflux_Sed = vec4<f32>(
            NumericalFlux(aplus, aminus, hW_east * uW_east * c1W_east, h_here.y * u_here.y * c1_here.y, phix * (hW_east * c1W_east - h_here.y * c1_here.y)),
            NumericalFlux(aplus, aminus, hW_east * uW_east * c2W_east, h_here.y * u_here.y * c2_here.y, phix * (hW_east * c2W_east - h_here.y * c2_here.y)),
            NumericalFlux(aplus, aminus, hW_east * uW_east * c3W_east, h_here.y * u_here.y * c3_here.y, phix * (hW_east * c3W_east - h_here.y * c3_here.y)),
            NumericalFlux(aplus, aminus, hW_east * uW_east * c4W_east, h_here.y * u_here.y * c4_here.y, phix * (hW_east * c4W_east - h_here.y * c4_here.y))
        );
            
       // let yflux_Sed = vec4<f32>(
       //     NumericalFlux(bplus, bminus, hS_north * c1S_north * vS_north, h_here.x * c1_here.x * v_here.x, phiy * (hS_north * c1S_north - h_here.x * c1_here.x)),
       //     NumericalFlux(bplus, bminus, hS_north * c2S_north * vS_north, h_here.x * c2_here.x * v_here.x, phiy * (hS_north * c2S_north - h_here.x * c2_here.x)),
       //     NumericalFlux(bplus, bminus, hS_north * c3S_north * vS_north, h_here.x * c3_here.x * v_here.x, phiy * (hS_north * c3S_north - h_here.x * c3_here.x)),
       //     NumericalFlux(bplus, bminus, hS_north * c4S_north * vS_north, h_here.x * c4_here.x * v_here.x, phiy * (hS_north * c4S_north - h_here.x * c4_here.x))
       // );

        textureStore(txXFlux_Sed, idx, xflux_Sed);
       // textureStore(txYFlux_Sed, idx, yflux_Sed);
    }
}
