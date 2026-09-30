%% FULL RECLASSIFICATION — 3-CLASS MODEL (hs / oi / os)
% Model: mdl_mod09ga_features_b1_7_dem_time_ndsi_ratios_xy_20260707_13_features
% Features (13): band_1-6, elevation, slope, time_sin, time_cos,
%                ratio_b1_b2, x_sinu, y_sinu
% Run this once from the repo root on Linux.

repoRoot  = '/data/joklar/verkefni/2026 - Spectral Glaciers/git/classify-mod09ga-images';
outputDir = '/data/SPICE/mod09ga';

% Pre-trained 3-class model (hs / oi / os) — 13 features including x/y sinusoidal coordinates.
modelPath = fullfile(repoRoot, 'classifiers', 'train_tables_and_models', 'mdl_mod09ga_features_b1_7_dem_time_ndsi_ratios_xy_20260707_13_features.mat');

% Inputs the model depends on. Passed explicitly (rather than relying on the
% classifier's internal defaults) so intent is visible and a missing path
% fails loudly here instead of silently falling back to MOD09GA state QA /
% NaN terrain features.
mod10a1Root = '/data/MOD10A1';                                   % MOD10A1 NDSI cloud mask
geoMatPath  = '/data/git/let-it-snow-2/geo/geo_let_it_snow.mat'; % elevation/slope/aspect

addpath(fullfile(repoRoot, 'helpers'));
addpath(fullfile(repoRoot, 'classifiers'));

% ── Fail loudly if required inputs are missing ───────────────────────────
assert(exist(modelPath, 'file') == 2, ...
    'Model not found: %s', modelPath);
assert(exist(mod10a1Root, 'dir') == 7, ...
    'MOD10A1 root not found: %s (cloud masking would silently fall back to MOD09GA state QA).', mod10a1Root);
assert(exist(geoMatPath, 'file') == 2, ...
    'Geo MAT not found: %s (elevation/slope/aspect features would be NaN).', geoMatPath);

% ── STEP 1: Classify all years ───────────────────────────────────────────
% Note: individual tiles are deleted only immediately before they are
% rewritten (inside localWriteNetcdf). Tiles not included in this run's
% year/date window are left untouched.
years = 2000:2026;
for y = years
    classify_mod09ga_tiles_to_spice(y, ...
        'ModelPath',    modelPath, ...
        'Mod10A1Root',  mod10a1Root, ...
        'GeoMatPath',   geoMatPath, ...
        'OutputRoot',   outputDir, ...
        'UseParallel',  true, ...
        'MaxWorkers',   48, ...    % cap workers to limit memory pressure on parpool startup
        'Overwrite',    true, ...
        'ApplyGapFill', true, ...
        'GapFillGeoMatPath', geoMatPath);
end

% ── Final sweep: gap-fill any tiles that were missed by per-year passes ──
% This catches tiles from previous runs that still have gap_fill_applied=0.
% Runs ONCE after all years are classified so neighbours are available.
fprintf('Running final gap-fill sweep for any remaining unfilled tiles...\n');
unfilled = dir(fullfile(outputDir, 'SPICE_MOD09GA.A*.nc'));
nSwept = 0;
for i = 1:numel(unfilled)
    fp = fullfile(unfilled(i).folder, unfilled(i).name);
    try
        applied = ncreadatt(fp, '/', 'gap_fill_applied');
    catch
        applied = 0;
    end
    if ~(isnumeric(applied) && applied == 0); continue; end

    tmpFp = [fp, '.gapfill_tmp.nc'];
    try
        r = fill_spice_tile_dem_model(fp, ...
            'DayWindow',  3, ...
            'SpiceDir',   outputDir, ...
            'GeoMatPath', geoMatPath, ...
            'ModelType',  'tree', ...
            'OutputPath', tmpFp);
        movefile(tmpFp, fp, 'f');
        nSwept = nSwept + 1;
        fprintf('  Sweep gap-filled: %s | %.1f%% -> %.1f%% -> 100%%\n', ...
            unfilled(i).name, r.metrics.coverageBeforePct, r.metrics.coverageAfterMergePct);
    catch ME
        fprintf('  Sweep gap-fill failed for %s: %s\n', unfilled(i).name, ME.message);
        if exist(tmpFp, 'file'); delete(tmpFp); end
    end
end
fprintf('Sweep complete: %d tile(s) gap-filled.\n', nSwept);

fprintf('Done.\n');
