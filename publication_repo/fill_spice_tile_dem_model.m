function result = fill_spice_tile_dem_model(referenceNcPath, varargin)
%FILL_SPICE_TILE_DEM_MODEL  Fill unclassified SPICE tile pixels via temporal
%   merging and a per-tile DEM-based classification model.
%
%   RESULT = FILL_SPICE_TILE_DEM_MODEL(REFERENCENCPATH) runs two gap-fill
%   stages on a SPICE NetCDF tile:
%
%     Stage 1 - Temporal merge
%       Searches for SPICE tiles of the same footprint within ±DayWindow
%       days.  For each neighbouring tile (closest day first) classified
%       pixels are copied into positions that are still zero in the
%       reference grid.
%
%     Stage 2 - DEM model
%       DEM and optional lat/lon/aspect are read directly from
%       geo_let_it_snow.mat on the same 2400x2400 MODIS grid. A local
%       classification tree (or
%       bagged ensemble) is trained on the already-classified glacier pixels
%       using {elevation, sin(aspect), cos(aspect), latitude, longitude} as
%       features.  The trained model then predicts the remaining
%       unclassified glacier pixels.
%
%   Name-value options:
%     'DayWindow'      Days ± reference date to search (default 3)
%     'SpiceDir'       Directory of SPICE NC files (default: folder of REFERENCENCPATH)
%     'GeoMatPath'     Path to geo_let_it_snow.mat (default: platform canonical)
%     'OutputPath'     Write filled NetCDF here; '' = no file output (default '')
%     'ModelType'      'tree' (default) or 'ensemble'
%
%   RESULT fields:
%     classGrid           (ny x nx int16) final class_id after all filling
%     metrics             struct with fields:
%                           glacierTotal, missingOrig,
%                           missingAfterMerge, missingAfterModel,
%                           pctFilledByMerge, pctFilledByModel
%     localModel          trained MATLAB classification model ([] if unused)
%     classInitial        class_id before gap filling
%     classAfterMerge     class_id after temporal merge only
%
%   Examples:
%     r = fill_spice_tile_dem_model( ...
%         '/data/SPICE/mod09ga/SPICE_MOD09GA.A2019152.h17v02.061.nc', ...
%         'DayWindow', 5);
%
%     r = fill_spice_tile_dem_model( ...
%         '/data/SPICE/mod09ga/SPICE_MOD09GA.A2019152.h17v02.061.nc', ...
%         'DayWindow', 3, 'ModelType', 'ensemble', ...
%         'OutputPath', '/data/SPICE/filled/SPICE_MOD09GA.A2019152.h17v02.061_filled.nc');

    defaultGeoMat = localDefaultGeoMatPath();

    p = inputParser;
    p.addRequired('referenceNcPath', @(x) ischar(x) || isstring(x));
    p.addParameter('DayWindow',  3,           @(x) isnumeric(x) && isscalar(x) && x >= 0);
    p.addParameter('SpiceDir',   '',          @(x) ischar(x) || isstring(x));
    p.addParameter('GeoMatPath', defaultGeoMat, @(x) ischar(x) || isstring(x));
    p.addParameter('OutputPath', '',          @(x) ischar(x) || isstring(x));
    p.addParameter('ModelType',  'tree',      @(x) any(strcmpi(char(string(x)), {'tree','ensemble'})));
    p.parse(referenceNcPath, varargin{:});
    args = p.Results;

    referenceNcPath = char(args.referenceNcPath);
    if ~exist(referenceNcPath, 'file')
        error('Reference NC file not found: %s', referenceNcPath);
    end

    % -------------------------------------------------------------------------
    % Read reference tile
    % -------------------------------------------------------------------------
    classRef         = int16(localReadBestClassification(referenceNcPath));
    glacierMask      = logical(ncread(referenceNcPath, 'glacier_mask') > 0);
    tileId           = localReadNcAttr(referenceNcPath, 'tile_id');
    dateStr          = localReadNcAttr(referenceNcPath, 'date');
    classMappingAttr = localReadNcAttr(referenceNcPath, 'class_mapping');
    [ny, nx]         = size(classRef);

    try
        refDate = datetime(dateStr, 'InputFormat', 'yyyy-MM-dd');
    catch
        error('Cannot parse date attribute from reference NC: "%s"', dateStr);
    end

    localLog(sprintf('Reference tile : %s', tileId));
    localLog(sprintf('Reference date : %s', dateStr));
    localLog(sprintf('Grid size      : %d x %d', ny, nx));

    % -------------------------------------------------------------------------
    % Baseline metrics
    % -------------------------------------------------------------------------
    glacierTotal = nnz(glacierMask);
    missingOrig  = nnz(glacierMask & classRef == 0);
    localLog(sprintf('Glacier pixels : %d  |  unclassified : %d  (%.1f%%)', ...
        glacierTotal, missingOrig, 100 * missingOrig / max(glacierTotal, 1)));

    classGrid = classRef;

    % -------------------------------------------------------------------------
    % Stage 1 – Temporal merge
    % -------------------------------------------------------------------------
    spiceDir  = char(args.SpiceDir);
    if isempty(spiceDir)
        spiceDir = fileparts(referenceNcPath);
    end
    dayWindow = round(double(args.DayWindow));

    if dayWindow > 0 && missingOrig > 0
        localLog(sprintf('Stage 1 – temporal merge (+-  %d days) ...', dayWindow));
        classGrid = localTemporalMerge(classGrid, glacierMask, ...
            spiceDir, tileId, refDate, dayWindow);
    else
        localLog('Stage 1 – temporal merge skipped (DayWindow=0 or no missing pixels).');
    end

    classAfterMerge   = classGrid;
    missingAfterMerge = nnz(glacierMask & classAfterMerge == 0);
    localLog(sprintf('After merge    : unclassified = %d  (%.1f%%)', ...
        missingAfterMerge, 100 * missingAfterMerge / max(glacierTotal, 1)));

    % -------------------------------------------------------------------------
    % Stage 2 – DEM-based local model
    % -------------------------------------------------------------------------
    localModel        = [];
    missingAfterModel = missingAfterMerge;

    if missingAfterMerge > 0
        localLog('Stage 2 – DEM-based model fill ...');
        [classGrid, localModel] = localDemModelFill( ...
            classGrid, glacierMask, char(args.GeoMatPath), ...
            char(args.ModelType), ny, nx);
        missingAfterModel = nnz(glacierMask & classGrid == 0);
        localLog(sprintf('After DEM model: unclassified = %d  (%.1f%%)', ...
            missingAfterModel, 100 * missingAfterModel / max(glacierTotal, 1)));
    else
        localLog('Stage 2 – DEM model skipped (no remaining gaps after merge).');
    end

    % -------------------------------------------------------------------------
    % Summary
    % -------------------------------------------------------------------------
    pctFilledByMerge = 100 * max(missingOrig - missingAfterMerge, 0)          / max(missingOrig, 1);
    pctFilledByModel = 100 * max(missingAfterMerge - missingAfterModel, 0)     / max(missingAfterMerge, 1);
    covBeforePct     = 100 * (glacierTotal - missingOrig)      / max(glacierTotal, 1);
    covAfterMergePct = 100 * (glacierTotal - missingAfterMerge) / max(glacierTotal, 1);
    covAfterModelPct = 100 * (glacierTotal - missingAfterModel) / max(glacierTotal, 1);

    localLog('');
    localLog('=== Gap-fill summary ===');
    localLog(sprintf('  Glacier pixels total         : %d', glacierTotal));
    localLog(sprintf('  Missing before fill          : %d  (%.1f%%)', ...
        missingOrig, 100 * missingOrig / max(glacierTotal, 1)));
    localLog(sprintf('  Missing after temporal merge : %d  (%.1f%%)', ...
        missingAfterMerge, 100 * missingAfterMerge / max(glacierTotal, 1)));
    localLog(sprintf('  Missing after DEM model      : %d  (%.1f%%)', ...
        missingAfterModel, 100 * missingAfterModel / max(glacierTotal, 1)));
    localLog(sprintf('  Filled by temporal merge     : %.1f%% of original gaps', pctFilledByMerge));
    localLog(sprintf('  Filled by DEM model          : %.1f%% of post-merge gaps', pctFilledByModel));
    localLog(sprintf('  Coverage before fill         : %.1f%%', covBeforePct));
    localLog(sprintf('  Coverage after merge         : %.1f%%', covAfterMergePct));
    localLog(sprintf('  Coverage after DEM model     : %.1f%%', covAfterModelPct));
    localLog('========================');

    metrics = struct( ...
        'glacierTotal',      glacierTotal, ...
        'missingOrig',       missingOrig, ...
        'missingAfterMerge', missingAfterMerge, ...
        'missingAfterModel', missingAfterModel, ...
        'pctFilledByMerge',  pctFilledByMerge, ...
        'pctFilledByModel',  pctFilledByModel, ...
        'coverageBeforePct', covBeforePct, ...
        'coverageAfterMergePct', covAfterMergePct, ...
        'coverageAfterModelPct', covAfterModelPct);

    result = struct( ...
        'classGrid', classGrid, ...
        'classInitial', classRef, ...
        'classAfterMerge', classAfterMerge, ...
        'metrics', metrics, ...
        'localModel', localModel);

    % -------------------------------------------------------------------------
    % Optional NetCDF output
    % -------------------------------------------------------------------------
    outputPath = char(args.OutputPath);
    if ~isempty(outputPath)
        outDir = fileparts(outputPath);
        if ~isempty(outDir) && ~exist(outDir, 'dir')
            mkdir(outDir);
        end
        localLog(sprintf('Writing filled NC: %s', outputPath));
        localWriteFilledNetcdf(outputPath, referenceNcPath, classRef, classAfterMerge, classGrid, metrics, ...
            tileId, dateStr, classMappingAttr);
        localLog('Done.');
    end
end

% =============================================================================
%  STAGE 1 – TEMPORAL MERGE
% =============================================================================
function classGrid = localTemporalMerge(classGrid, glacierMask, spiceDir, tileId, refDate, dayWindow)
    tileCode = regexp(char(tileId), 'h\d{2}v\d{2}', 'match', 'once');
    if isempty(tileCode)
        warning('Cannot parse tile code from tileId "%s". Temporal merge skipped.', tileId);
        return;
    end

    ncFiles = dir(fullfile(spiceDir, sprintf('SPICE_MOD09GA.A*.%s.*.nc', tileCode)));
    if isempty(ncFiles)
        warning('No SPICE files found in %s for tile %s. Temporal merge skipped.', spiceDir, tileCode);
        return;
    end

    dates = NaT(numel(ncFiles), 1);
    for i = 1:numel(ncFiles)
        dates(i) = localParseDateFromNcName(ncFiles(i).name);
    end

    validIdx = ~isnat(dates);
    ncFiles  = ncFiles(validIdx);
    dates    = dates(validIdx);
    dayDiffs = days(dates - refDate);

    inWindow = abs(dayDiffs) <= dayWindow & dayDiffs ~= 0;
    ncFiles  = ncFiles(inWindow);
    dayDiffs = dayDiffs(inWindow);

    if isempty(ncFiles)
        localLog('  No neighbouring SPICE tiles found within day window.');
        return;
    end

    [~, sortIdx] = sort(abs(dayDiffs));
    ncFiles  = ncFiles(sortIdx);
    dayDiffs = dayDiffs(sortIdx);

    localLog(sprintf('  Found %d neighbouring tiles within +- %d days.', numel(ncFiles), dayWindow));

    for i = 1:numel(ncFiles)
        stillMissing = glacierMask & classGrid == 0;
        if ~any(stillMissing(:))
            break;
        end

        ncPath = fullfile(ncFiles(i).folder, ncFiles(i).name);
        try
            % Read the best available classification from the neighbour tile
            % (classification_gap_filled > temporal > original, in that order).
            % Cloud and glacier masking are IMPLICIT: during classification,
            % cloud-contaminated and non-glacier pixels were assigned class_id = 0.
            % The fillMask below only copies pixels where other > 0, so only
            % previously-classified valid glacier pixels propagate — never
            % cloud or outside-glacier pixels.
            %
            % IMPORTANT: only read classification_original from neighbours.
            % Using classification_gap_filled would create a cascade: once day N
            % is fully filled (including DEM-model predictions), day N+1 reads
            % that 100%-filled grid and also becomes 100% filled, regardless of
            % actual cloud cover.  We want temporal merge to propagate only
            % direct clear-sky observations; the DEM model fills what genuinely
            % had no clear-sky neighbour within the window.
            neighbourVars = {'classification_original', 'class_id'};
            other = [];
            for vi = 1:numel(neighbourVars)
                try
                    other = int16(ncread(ncPath, neighbourVars{vi}));
                    break;
                catch
                end
            end
            if isempty(other)
                localLog(sprintf('No original classification found in %s — skipping.', ncFiles(i).name));
                continue;
            end
            if ~isequal(size(other), size(classGrid))
                continue;
            end
            fillMask  = stillMissing & other > 0;
            nFilled   = nnz(fillMask);
            classGrid(fillMask) = other(fillMask);
            localLog(sprintf('  [day %+d] filled %d pixels  <- %s', ...
                round(dayDiffs(i)), nFilled, ncFiles(i).name));
        catch ME
            localLog(sprintf('Failed to read %s: %s', ncPath, ME.message));
        end
    end
end

% =============================================================================
%  STAGE 2 – DEM-BASED LOCAL MODEL FILL
% =============================================================================
function [classGrid, mdl] = localDemModelFill(classGrid, glacierMask, geoMatPath, modelType, ny, nx)
    mdl = [];
    % Load geo arrays directly – they are already on the same 2400x2400 grid
    [elevGrid, slopeGrid, aspectGrid, latGrid, lonGrid, geoOk] = localLoadGeoArrays(geoMatPath, ny, nx);
    if ~geoOk
        return;
    end

    % Encode aspect as sin/cos to handle circular wraparound.
    % Replace NaN aspect (flat/undefined terrain) with 0 deg so no glacier
    % pixels are excluded solely because aspect is undefined.
    useAspect = any(isfinite(aspectGrid(:)));
    if useAspect
        aspectFilled = double(aspectGrid);
        aspectFilled(~isfinite(aspectFilled)) = 0;
        sinAsp = sin(deg2rad(aspectFilled));
        cosAsp = cos(deg2rad(aspectFilled));
    end

    useSlope  = any(isfinite(slopeGrid(:)));

    % lat/lon are optional features: use them only when the geo struct
    % contains them.  If missing, every glacier pixel with valid elevation
    % can still be classified.
    useLatLon = any(isfinite(latGrid(:))) && any(isfinite(lonGrid(:)));

    % ---- Training set -------------------------------------------------------
    % Only elevation is required to be finite; aspect NaN already replaced.
    trainMask = glacierMask & classGrid > 0 & isfinite(elevGrid);

    nTrain = nnz(trainMask);
    if nTrain < 20
        warning('Only %d training pixels available (minimum 20). DEM model skipped.', nTrain);
        return;
    end

    trainLabels   = double(classGrid(trainMask));
    trainFeatures = localBuildFeatureTable( ...
        elevGrid, slopeGrid, sinAsp, cosAsp, latGrid, lonGrid, trainMask, useAspect, useSlope, useLatLon);

    localLog(sprintf('  Training %s model on %d glacier pixels (%d classes).', ...
        modelType, nTrain, numel(unique(trainLabels))));
    localLog(sprintf('  Features: elevation%s%s%s', ...
        localTernStr(useSlope,  ' + slope', ''), ...
        localTernStr(useAspect, ' + sin/cos_aspect', ''), ...
        localTernStr(useLatLon, ' + lat/lon', ' (lat/lon not in geo struct)')));

    try
        if strcmpi(modelType, 'ensemble')
            mdl = fitcensemble(trainFeatures, trainLabels, ...
                'Method', 'Bag', 'NumLearningCycles', 50, 'Learners', 'tree');
        else
            mdl = fitctree(trainFeatures, trainLabels, 'MinLeafSize', 5);
        end
    catch ME
        localLog(sprintf('DEM model training failed: %s', ME.message));
        return;
    end

    % ---- Prediction set -----------------------------------------------------
    predMask = glacierMask & classGrid == 0 & isfinite(elevGrid);
    nPred    = nnz(predMask);

    if nPred == 0
        localLog('  No pixels remaining for DEM model prediction.');
        return;
    end

    predFeatures = localBuildFeatureTable( ...
        elevGrid, slopeGrid, sinAsp, cosAsp, latGrid, lonGrid, predMask, useAspect, useSlope, useLatLon);

    try
        predicted = predict(mdl, predFeatures);
        classGrid(predMask) = int16(predicted);
        localLog(sprintf('  DEM model classified %d pixels.', nPred));
    catch ME
        localLog(sprintf('DEM model prediction failed: %s', ME.message));
    end

    stillMissing = nnz(glacierMask & classGrid == 0);
    if stillMissing > 0
        localLog(sprintf('  %d glacier pixels remain unclassified (no valid elevation in geo data).', ...
            stillMissing));
    end
end

function T = localBuildFeatureTable(elevGrid, slopeGrid, sinAsp, cosAsp, latGrid, lonGrid, mask, useAspect, useSlope, useLatLon)
    e  = double(elevGrid(mask));
    sl = double(slopeGrid(mask));
    T  = table(e, 'VariableNames', {'elevation'});
    if useSlope
        T.slope = sl;
    end
    if useAspect
        T.sin_aspect = sinAsp(mask);
        T.cos_aspect = cosAsp(mask);
    end
    if useLatLon
        T.latitude  = double(latGrid(mask));
        T.longitude = double(lonGrid(mask));
    end
end

function s = localTernStr(cond, trueStr, falseStr)
    if cond; s = trueStr; else; s = falseStr; end
end

% =============================================================================
%  LOAD GEO ARRAYS DIRECTLY FROM MAT FILE
%  The geo struct arrays are already on the same 2400x2400 MODIS grid –
%  no reprojection or interpolation is needed.
% =============================================================================
function [elevGrid, slopeGrid, aspectGrid, latGrid, lonGrid, ok] = localLoadGeoArrays(geoMatPath, ny, nx)
    elevGrid   = nan(ny, nx);
    slopeGrid  = nan(ny, nx);
    aspectGrid = nan(ny, nx);
    latGrid    = nan(ny, nx);
    lonGrid    = nan(ny, nx);
    ok         = false;

    if ~exist(geoMatPath, 'file')
        warning('Geo MAT file not found: %s', geoMatPath);
        return;
    end

    localLog(sprintf('  Loading geo data: %s', geoMatPath));
    try
        raw = load(geoMatPath);
    catch ME
        localLog(sprintf('Failed to load geo MAT: %s', ME.message));
        return;
    end

    gs = localExtractGeoStruct(raw);
    if isempty(gs)
        warning('No usable geo structure found in %s.  Top-level fields: %s', ...
            geoMatPath, strjoin(fieldnames(raw), ', '));
        return;
    end

    latField    = localFindField(gs, {'lat','latitude','Lat','LAT'});
    lonField    = localFindField(gs, {'lon','longitude','Lon','LON'});
    elevField   = localFindField(gs, {'elevation','elev','dem','DEM','z','height','alt','altitude'});
    aspectField = localFindField(gs, {'aspect','Aspect','ASPECT','slope_aspect'});
    slopeField  = localFindField(gs, {'slope','Slope','SLOPE','gradient','grad'});

    if isempty(elevField)
        warning('Geo struct missing elevation field (found: %s).', strjoin(fieldnames(gs), ', '));
        return;
    end

    raw_elev = gs.(elevField);
    if isstruct(raw_elev)
        % Common geo.dem layout: dem.z=elevation, dem.a=aspect, dem.s=slope.
        nestedElevField   = localFindField(raw_elev, {'z','elevation','elev','dem','height','alt','altitude'});
        nestedAspectField = localFindField(raw_elev, {'a','aspect','Aspect','ASPECT','slope_aspect'});
        nestedSlopeField  = localFindField(raw_elev, {'s','slope','Slope','SLOPE','gradient'});
        if isempty(nestedElevField)
            warning('Elevation field "%s" is a struct without numeric elevation subfield.', elevField);
            return;
        end
        elevGrid = localResizeGeoArray(double(raw_elev.(nestedElevField)), ny, nx);
        if isempty(aspectField) && ~isempty(nestedAspectField)
            aspectGrid = localResizeGeoArray(double(raw_elev.(nestedAspectField)), ny, nx);
        end
        if isempty(slopeField) && ~isempty(nestedSlopeField)
            slopeGrid = localResizeGeoArray(double(raw_elev.(nestedSlopeField)), ny, nx);
        end
    else
        elevGrid = localResizeGeoArray(double(raw_elev), ny, nx);
    end

    if ~isempty(aspectField) && ~isstruct(gs.(aspectField))
        aspectGrid = localResizeGeoArray(double(gs.(aspectField)), ny, nx);
    end
    if ~isempty(slopeField) && ~isstruct(gs.(slopeField))
        slopeGrid = localResizeGeoArray(double(gs.(slopeField)), ny, nx);
    end
    if ~isempty(latField) && ~isstruct(gs.(latField))
        latGrid = localResizeGeoArray(double(gs.(latField)), ny, nx);
    end
    if ~isempty(lonField) && ~isstruct(gs.(lonField))
        lonGrid = localResizeGeoArray(double(gs.(lonField)), ny, nx);
    end

    % Derive slope from elevation when no slope field was found in the mat file.
    if ~any(isfinite(slopeGrid(:))) && any(isfinite(elevGrid(:)))
        localLog('  No slope field — deriving from elevation grid (MODIS 463.3 m pixels).');
        [dzdx, dzdy] = gradient(elevGrid, 463.312716527778);
        slopeGrid = atand(sqrt(dzdx.^2 + dzdy.^2));
    end

    ok = any(isfinite(elevGrid(:)));
    if ~ok
        warning('Elevation array contains no finite values.');
    end
end

function arr = localResizeGeoArray(arr, ny, nx)
    % Geo arrays must match the tile grid; attempt transpose if needed.
    if isequal(size(arr), [ny, nx])
        return;
    end
    if isequal(size(arr), [nx, ny])
        arr = arr';
        return;
    end
    warning('Geo array size %s does not match expected %dx%d; using as-is.', ...
        mat2str(size(arr)), ny, nx);
end

% =============================================================================
%  WRITE FILLED NETCDF
% =============================================================================
function localWriteFilledNetcdf(outputPath, referenceNcPath, classInitial, classAfterMerge, classFinal, metrics, tileId, dateStr, classMappingAttr)
    if exist(outputPath, 'file')
        delete(outputPath);
    end

    [ny, nx] = size(classFinal);

    % Copy non-classification grid variables from the reference tile
    copyVars = {'glacier_mask', 'cloud_free_mask'};
    for i = 1:numel(copyVars)
        try
            data = ncread(referenceNcPath, copyVars{i});
            info = ncinfo(referenceNcPath, copyVars{i});
            nccreate(outputPath, copyVars{i}, ...
                'Dimensions', {'y', ny, 'x', nx}, ...
                'Datatype',   info.Datatype, ...
                'DeflateLevel', 5);
            ncwrite(outputPath, copyVars{i}, data);
            for a = 1:numel(info.Attributes)
                ncwriteatt(outputPath, copyVars{i}, info.Attributes(a).Name, info.Attributes(a).Value);
            end
        catch
        end
    end

    % Write the three classification stages
    nccreate(outputPath, 'classification_original', ...
        'Dimensions', {'y', ny, 'x', nx}, 'Datatype', 'int16', 'DeflateLevel', 5);
    ncwrite(outputPath, 'classification_original', int16(classInitial));
    ncwriteatt(outputPath, 'classification_original', 'long_name', 'SPICE class id before gap filling');

    nccreate(outputPath, 'classification_temporal', ...
        'Dimensions', {'y', ny, 'x', nx}, 'Datatype', 'int16', 'DeflateLevel', 5);
    ncwrite(outputPath, 'classification_temporal', int16(classAfterMerge));
    ncwriteatt(outputPath, 'classification_temporal', 'long_name', 'SPICE class id after temporal day-window merge');

    nccreate(outputPath, 'classification_gap_filled', ...
        'Dimensions', {'y', ny, 'x', nx}, 'Datatype', 'int16', 'DeflateLevel', 5);
    ncwrite(outputPath, 'classification_gap_filled', int16(classFinal));
    ncwriteatt(outputPath, 'classification_gap_filled', 'long_name', ...
        'SPICE class id (final: temporal-merge + DEM-model gap-filled)');
    ncwriteatt(outputPath, 'classification_gap_filled', 'description', ...
        '0=unclassified; 1..N mapped via class_mapping global attribute');

    % ── Global attributes ─────────────────────────────────────────────────
    % First carry over ALL global attributes from the reference tile so that
    % model_name, model_features, cloud_mask_source, glacier_outline_* etc.
    % are preserved.  Gap-fill specific attributes are then overwritten below.
    try
        refInfo = ncinfo(referenceNcPath);
        for a = 1:numel(refInfo.Attributes)
            try
                ncwriteatt(outputPath, '/', refInfo.Attributes(a).Name, refInfo.Attributes(a).Value);
            catch; end
        end
    catch; end

    % Overwrite / add the gap-fill specific attributes
    ncwriteatt(outputPath, '/', 'title',         'SPICE MOD09GA gap-filled classification');
    ncwriteatt(outputPath, '/', 'tile_id',        tileId);
    ncwriteatt(outputPath, '/', 'date',           dateStr);
    ncwriteatt(outputPath, '/', 'class_mapping',  classMappingAttr);
    ncwriteatt(outputPath, '/', 'gap_fill_applied', int16(1));
    ncwriteatt(outputPath, '/', 'gap_fill_glacier_total',       int32(metrics.glacierTotal));
    ncwriteatt(outputPath, '/', 'gap_fill_missing_orig',        int32(metrics.missingOrig));
    ncwriteatt(outputPath, '/', 'gap_fill_missing_merge',       int32(metrics.missingAfterMerge));
    ncwriteatt(outputPath, '/', 'gap_fill_missing_model',       int32(metrics.missingAfterModel));
    ncwriteatt(outputPath, '/', 'gap_fill_pct_by_merge',        single(metrics.pctFilledByMerge));
    ncwriteatt(outputPath, '/', 'gap_fill_pct_by_model',        single(metrics.pctFilledByModel));
    ncwriteatt(outputPath, '/', 'gap_fill_coverage_before_pct', single(metrics.coverageBeforePct));
    ncwriteatt(outputPath, '/', 'gap_fill_coverage_merge_pct',  single(metrics.coverageAfterMergePct));
    ncwriteatt(outputPath, '/', 'gap_fill_coverage_model_pct',  single(metrics.coverageAfterModelPct));
    summaryText = sprintf(['missing: %d -> %d -> %d (before -> temporal -> model); ', ...
        'coverage: %.2f%% -> %.2f%% -> %.2f%%'], ...
        metrics.missingOrig, metrics.missingAfterMerge, metrics.missingAfterModel, ...
        metrics.coverageBeforePct, metrics.coverageAfterMergePct, metrics.coverageAfterModelPct);
    ncwriteatt(outputPath, '/', 'gap_fill_summary', summaryText);
    ncwriteatt(outputPath, '/', 'created_utc', ...
        char(datetime('now', 'TimeZone', 'UTC', 'Format', 'yyyy-MM-dd''T''HH:mm:ss''Z''')));

    localWriteClassMetadata(outputPath, classMappingAttr);
end

% =============================================================================
%  HELPERS
% =============================================================================
function d = localParseDateFromNcName(name)
    d = NaT;
    tok = regexp(name, 'MOD09GA\.A(\d{4})(\d{3})\.', 'tokens', 'once');
    if isempty(tok)
        return;
    end
    d = datetime(str2double(tok{1}), 1, 1) + days(str2double(tok{2}) - 1);
end

function val = localReadNcAttr(ncPath, attrName)
    val = '';
    try
        val = char(ncreadatt(ncPath, '/', attrName));
    catch
    end
end

function classGrid = localReadBestClassification(ncPath)
    candidates = {'classification_gap_filled', 'classification_temporal', 'classification_original', 'class_id'};
    for i = 1:numel(candidates)
        try
            classGrid = ncread(ncPath, candidates{i});
            return;
        catch
        end
    end
    error('No classification variable found in %s. Tried: %s', ncPath, strjoin(candidates, ', '));
end

function localWriteClassMetadata(outPath, classMappingAttr)
    [classIds, classNames] = localParseClassMapping(classMappingAttr);
    if isempty(classIds)
        return;
    end

    nameLen = max(strlength(classNames));
    if isempty(nameLen) || nameLen < 1
        nameLen = 1;
    end
    nameLen = double(nameLen);

    nccreate(outPath, 'class_values', 'Dimensions', {'class', numel(classIds)}, ...
        'Datatype', 'int16', 'DeflateLevel', 5);
    ncwrite(outPath, 'class_values', int16(classIds));
    ncwriteatt(outPath, 'class_values', 'long_name', 'Class numeric ids');

    nameMat = repmat(' ', numel(classIds), nameLen);
    for i = 1:numel(classIds)
        nameChar = char(classNames(i));
        n = min(numel(nameChar), nameLen);
        if n > 0
            nameMat(i, 1:n) = nameChar(1:n);
        end
    end

    nccreate(outPath, 'class_names', 'Dimensions', {'class', numel(classIds), 'name_strlen', nameLen}, ...
        'Datatype', 'char', 'DeflateLevel', 5);
    ncwrite(outPath, 'class_names', nameMat);
    ncwriteatt(outPath, 'class_names', 'long_name', 'Class names aligned with class_values');
end

function [ids, names] = localParseClassMapping(classMappingAttr)
    ids = zeros(0, 1);
    names = strings(0, 1);
    if isempty(classMappingAttr)
        return;
    end

    parts = regexp(char(classMappingAttr), '\s*,\s*', 'split');
    for i = 1:numel(parts)
        tok = regexp(parts{i}, '^\s*(\d+)\s*:\s*(.+?)\s*$', 'tokens', 'once');
        if isempty(tok)
            continue;
        end
        ids(end + 1, 1) = str2double(tok{1}); %#ok<AGROW>
        names(end + 1, 1) = string(tok{2}); %#ok<AGROW>
    end
end

function gs = localExtractGeoStruct(raw)
    gs = [];
    % Primary: expect a 'geo' field as in geo_let_it_snow.mat
    if isfield(raw, 'geo') && isstruct(raw.geo)
        gs = raw.geo;
        return;
    end
    % Secondary: first struct-valued field
    f = fieldnames(raw);
    for i = 1:numel(f)
        if isstruct(raw.(f{i}))
            gs = raw.(f{i});
            return;
        end
    end
    % Tertiary: top-level struct has geo fields directly
    if isfield(raw, 'lat') || isfield(raw, 'latitude') || isfield(raw, 'elevation') || isfield(raw, 'elev')
        gs = raw;
    end
end

function fname = localFindField(s, candidates)
    fname = '';
    for i = 1:numel(candidates)
        if isfield(s, candidates{i})
            fname = candidates{i};
            return;
        end
    end
end

function p = localDefaultGeoMatPath()
    pathLinux   = '/data/git/let-it-snow-2/geo/geo_let_it_snow.mat';
    pathWindows = '\\lv-reikni-01.lv.is\data\git\let-it-snow-2\geo\geo_let_it_snow.mat';
    if ispc()
        preferred = {pathWindows, pathLinux};
    else
        preferred = {pathLinux, pathWindows};
    end
    p = preferred{1};
    for i = 1:numel(preferred)
        if exist(preferred{i}, 'file')
            p = preferred{i};
            return;
        end
    end
end

function localLog(msg)
    fprintf('[%s] %s\n', char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')), msg);
end
