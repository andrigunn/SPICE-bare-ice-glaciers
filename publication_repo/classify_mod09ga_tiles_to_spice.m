function classify_mod09ga_tiles_to_spice(targetYear, varargin)
%CLASSIFY_MOD09GA_TILES_TO_SPICE Classify MOD09GA tiles and export SPICE NetCDF.
%   CLASSIFY_MOD09GA_TILES_TO_SPICE(TARGETYEAR) processes MOD09GA files for
%   TARGETYEAR between 1-Apr and 30-Sep, masks non-glacier areas using the
%   closest-year glacier outline, masks cloud-contaminated pixels using
%   MOD09GA state QA, classifies glacier pixels with the trained
%   model, and writes one NetCDF per tile:
%     /data/SPICE/mod09ga/SPICE_<MOD09GA_TILE_ID>.nc
%
%   Name-value options:
%     'ModisRoot'      (default '/data/MOD09GA' on Linux)
%     'Mod10A1Root'    Path to MOD10A1 HDF files used for cloud masking.
%                      Cloud-free = NDSI_Snow_Cover <= 100 (valid retrieval) OR
%                      == 201 (no-decision, which is commonly assigned to glacier
%                      surfaces such as wet ice / firn and is NOT cloud).
%                      Only value 250 (cloud), 211 (night), 237/239 (water), and
%                      253-255 (fill) are treated as masked.
%                      Falls back to MOD09GA state_1km QA if no MOD10A1 file found.
%                      (default '/data/MOD10A1' on Linux)
%     'GlacierRoot'    (default '/data/spectral_glaciers' on Linux)
%     'ModelPath'      (default classify_mod09ga_polygons_model_v20260625.mat)
%     'GeoMatPath'     Path to geo_let_it_snow.mat for elevation/slope/aspect
%                      features.  Only used when the loaded model's RequiredVariables
%                      include these columns — models trained with band-only data
%                      will not use it at all.  (default: platform canonical path)
%     'OutputRoot'     (default '/data/SPICE/mod09ga' on Linux)
%     'UseParallel'    (default true)
%     'MaxWorkers'     (default [])
%     'MaxTiles'       (default inf)
%     'Overwrite'      (default true)
%     'ApplyGapFill'   (default true)
%     'GapFillDayWindow' (default 3)
%     'GapFillGeoMatPath' (default platform path to geo_let_it_snow.mat)
%     'GapFillModelType' ('tree' default or 'ensemble')
%     'RemapDirtySnowTo' Remap dirty-snow (os) predictions to another class
%                      without retraining. Options: '' (default, keep os as-is),
%                      'hs' (remap to snow), 'oi' (remap to ice).
%
%   Example:
%     classify_mod09ga_tiles_to_spice(2026,'UseParallel', true,'OutputRoot', '/data/SPICE/mod09ga');

    if nargin < 1
        error('targetYear is required, for example: classify_mod09ga_tiles_to_spice(2024).');
    end

    if ispc()
        dataRoot = '\\lv-reikni-01.lv.is\data';
    else
        dataRoot = '/data';
    end
    scriptDir = fileparts(mfilename('fullpath'));
    defaultModelPath = fullfile(scriptDir, 'train_tables_and_models', 'classify_mod09ga_polygons_model_v20260625.mat');

    p = inputParser;
    p.addRequired('targetYear', @(x) isnumeric(x) && isscalar(x) && x >= 1900 && x <= 2500);
    p.addParameter('ModisRoot',      fullfile(dataRoot, 'MOD09GA'),           @(x) ischar(x) || isstring(x));
    p.addParameter('Mod10A1Root',    fullfile(dataRoot, 'MOD10A1'),           @(x) ischar(x) || isstring(x));
    p.addParameter('GlacierRoot',    fullfile(dataRoot, 'spectral_glaciers'), @(x) ischar(x) || isstring(x));
    p.addParameter('ModelPath',      defaultModelPath,                        @(x) ischar(x) || isstring(x));
    p.addParameter('GeoMatPath',     localDefaultGeoMatPath(),                @(x) ischar(x) || isstring(x));
    p.addParameter('OutputRoot',     fullfile(dataRoot, 'SPICE', 'mod09ga'), @(x) ischar(x) || isstring(x));
    p.addParameter('UseParallel',    true,    @(x) islogical(x) || isnumeric(x));
    p.addParameter('MaxWorkers',     [],      @(x) isempty(x) || (isnumeric(x) && isscalar(x) && x >= 1));
    p.addParameter('MaxTiles',       inf,     @(x) isnumeric(x) && isscalar(x) && x >= 1);
    p.addParameter('Overwrite',      true,    @(x) islogical(x) || isnumeric(x));
    p.addParameter('ApplyGapFill',   true,    @(x) islogical(x) || isnumeric(x));
    p.addParameter('GapFillDayWindow',  3,      @(x) isnumeric(x) && isscalar(x) && x >= 0);
    p.addParameter('GapFillGeoMatPath', localDefaultGeoMatPath(), @(x) ischar(x) || isstring(x));
    p.addParameter('GapFillModelType',  'tree', @(x) any(strcmpi(char(string(x)), {'tree','ensemble'})));
    p.addParameter('RemapDirtySnowTo',  '',     @(x) ischar(x) || isstring(x));
    p.parse(targetYear, varargin{:});
    args = p.Results;

    targetYear = double(targetYear);
    modisRoot        = char(args.ModisRoot);
    mod10a1Root      = char(args.Mod10A1Root);
    glacierRoot      = char(args.GlacierRoot);
    modelPath        = char(args.ModelPath);
    geoMatPath       = char(args.GeoMatPath);
    outputRoot       = char(args.OutputRoot);
    useParallel      = logical(args.UseParallel);
    maxWorkers       = args.MaxWorkers;
    maxTiles         = double(args.MaxTiles);
    overwrite        = logical(args.Overwrite);
    applyGapFill     = logical(args.ApplyGapFill);
    gapFillDayWindow = round(double(args.GapFillDayWindow));
    gapFillGeoMatPath = char(args.GapFillGeoMatPath);
    gapFillModelType  = char(args.GapFillModelType);
    remapDirtySnowTo  = lower(strtrim(char(string(args.RemapDirtySnowTo))));
    if ~isempty(remapDirtySnowTo) && ~any(strcmp(remapDirtySnowTo, {'hs', 'oi'}))
        error('RemapDirtySnowTo must be '''' (keep), ''hs'' (snow), or ''oi'' (ice).');
    end
    if ~isempty(remapDirtySnowTo)
        localLog(sprintf('DirtySnow (os) pixels will be remapped to: %s', remapDirtySnowTo));
    end

    if ~exist(outputRoot, 'dir')
        mkdir(outputRoot);
    end

    localLog(sprintf('Starting SPICE classification for year %d.', targetYear));
    localLog(sprintf('MODIS root: %s', modisRoot));
    localLog(sprintf('MOD10A1 root: %s', mod10a1Root));
    localLog(sprintf('Glacier root: %s', glacierRoot));
    localLog(sprintf('Model path: %s', modelPath));
    localLog(sprintf('Geo MAT: %s', geoMatPath));
    localLog(sprintf('Output root: %s', outputRoot));
    if applyGapFill
        localLog('Gap fill stage enabled.');
        localLog(sprintf('GapFillDayWindow: %d', gapFillDayWindow));
        localLog(sprintf('GapFillGeoMatPath: %s', gapFillGeoMatPath));
        localLog(sprintf('GapFillModelType: %s', gapFillModelType));
    end

    % Load geo terrain data once — only used when the model needs elevation/slope/aspect.
    geoData = localLoadGeoData(geoMatPath);
    localLog(sprintf('Geo data — elevation ok: %d, slope ok: %d, aspect ok: %d', ...
        any(isfinite(geoData.elevation(:))), any(isfinite(geoData.slope(:))), any(isfinite(geoData.aspect(:)))));

    modelStruct = load(modelPath);
    % Support any variable name: prefer 'trainedModel', else pick the first struct.
    if isfield(modelStruct, 'trainedModel')
        trainedModel = modelStruct.trainedModel;
    else
        fn = fieldnames(modelStruct);
        trainedModel = modelStruct.(fn{1});
    end
    requiredVars = trainedModel.RequiredVariables;
    classNames = cellstr(string(trainedModel.ClassificationTree.ClassNames));
    localLog(sprintf('Loaded model with classes: %s', strjoin(classNames, ', ')));
    localLog(sprintf('Model requires %d features: %s', numel(requiredVars), strjoin(cellstr(requiredVars), ', ')));

    % Pre-flight: verify every required feature can be computed and warn on gaps.
    localValidateModelFeatures(requiredVars, geoData, mod10a1Root, modisRoot, targetYear);

    [glacierShp, glacierYear] = localSelectClosestGlacierOutline(glacierRoot, targetYear);
    localLog(sprintf('Using glacier outline year %d: %s', glacierYear, glacierShp));

    allTiles = dir(fullfile(modisRoot, sprintf('MOD09GA.A%d*.hdf', targetYear)));
    if isempty(allTiles)
        localLog('No MOD09GA files found for target year. Nothing to do.');
        return;
    end

    dateStart = datetime(targetYear, 4, 1);
    dateEnd = datetime(targetYear, 9, 30);
    keep = false(numel(allTiles), 1);
    tileDates = NaT(numel(allTiles), 1);
    tileIds = strings(numel(allTiles), 1);
    for i = 1:numel(allTiles)
        [tileDate, tileId] = localParseModisDateAndTileId(allTiles(i).name);
        tileDates(i) = tileDate;
        tileIds(i) = string(tileId);
        if ~isnat(tileDate) && tileDate >= dateStart && tileDate <= dateEnd
            keep(i) = true;
        end
    end

    allTiles = allTiles(keep);
    tileDates = tileDates(keep);
    tileIds = tileIds(keep);

    if isempty(allTiles)
        localLog('No MOD09GA files found in the requested date window (Apr 1 to Sep 30).');
        return;
    end

    [tileDates, sortIdx] = sort(tileDates);
    allTiles = allTiles(sortIdx);
    tileIds = tileIds(sortIdx);

    if isfinite(maxTiles)
        nTake = min(numel(allTiles), maxTiles);
        allTiles = allTiles(1:nTake);
        tileDates = tileDates(1:nTake);
        tileIds = tileIds(1:nTake);
    end

    localLog(sprintf('Tiles selected for classification: %d', numel(allTiles)));

    % Build glacier mask once for this tile grid (h17v02 is fixed here).
    sampleFile = fullfile(allTiles(1).folder, allTiles(1).name);
    [~, sampleRef] = localReadSingleBand(sampleFile, 1);
    glacierMask = localBuildGlacierMask(glacierShp, sampleRef, [2400, 2400]);
    localLog(sprintf('Glacier mask prepared with %d glacier pixels.', nnz(glacierMask)));

    tilePaths = fullfile({allTiles.folder}, {allTiles.name});

    if useParallel && license('test', 'Distrib_Computing_Toolbox') && ~isempty(ver('parallel'))
        pool = gcp('nocreate');
        if isempty(pool)
            if isempty(maxWorkers)
                parpool;
            else
                parpool('local', maxWorkers);
            end
        elseif ~isempty(maxWorkers) && pool.NumWorkers ~= maxWorkers
            delete(pool);
            parpool('local', maxWorkers);
        end

        modelConst       = parallel.pool.Constant(trainedModel);
        requiredVarsConst = parallel.pool.Constant(requiredVars);
        classNamesConst  = parallel.pool.Constant(classNames);
        glacierMaskConst = parallel.pool.Constant(glacierMask);
        glacierShpConst  = parallel.pool.Constant(glacierShp);
        geoDataConst     = parallel.pool.Constant(geoData);
        mod10a1RootConst = parallel.pool.Constant(mod10a1Root);
        modelPathConst   = parallel.pool.Constant(modelPath);
        remapConst       = parallel.pool.Constant(remapDirtySnowTo);
        parfor i = 1:numel(tilePaths)
            localClassifySingleTile(tilePaths{i}, tileDates(i), tileIds(i), ...
                modelConst.Value, requiredVarsConst.Value, classNamesConst.Value, ...
                glacierMaskConst.Value, glacierShpConst.Value, outputRoot, overwrite, ...
                remapConst.Value, geoDataConst.Value, mod10a1RootConst.Value, modelPathConst.Value);
        end
    else
        for i = 1:numel(tilePaths)
            localClassifySingleTile(tilePaths{i}, tileDates(i), tileIds(i), ...
                trainedModel, requiredVars, classNames, glacierMask, glacierShp, outputRoot, overwrite, ...
                remapDirtySnowTo, geoData, mod10a1Root, modelPath);
        end
    end

    localLog('Finished SPICE tile classification.');

    if applyGapFill
        localRunGapFillPass(tileIds, outputRoot, gapFillDayWindow, gapFillGeoMatPath, gapFillModelType);
    end
end

function localRunGapFillPass(tileIds, outputRoot, dayWindow, geoMatPath, modelType)
    localLog('Starting gap-fill pass (temporal merge + DEM model).');

    nProcessed = 0;
    missingOrigTotal = 0;
    missingMergeTotal = 0;
    missingModelTotal = 0;
    glacierTotal = 0;

    for i = 1:numel(tileIds)
        outPath = fullfile(outputRoot, sprintf('SPICE_%s.nc', char(tileIds(i))));
        if ~exist(outPath, 'file')
            continue;
        end

        tempOut = [outPath, '.gapfill_tmp.nc'];
        try
            if exist(tempOut, 'file')
                delete(tempOut);
            end

            r = fill_spice_tile_dem_model(outPath, ...
                'DayWindow', dayWindow, ...
                'SpiceDir', outputRoot, ...
                'GeoMatPath', geoMatPath, ...
                'ModelType', modelType, ...
                'OutputPath', tempOut);

            movefile(tempOut, outPath, 'f');

            nProcessed = nProcessed + 1;
            missingOrigTotal = missingOrigTotal + r.metrics.missingOrig;
            missingMergeTotal = missingMergeTotal + r.metrics.missingAfterMerge;
            missingModelTotal = missingModelTotal + r.metrics.missingAfterModel;
            glacierTotal = glacierTotal + r.metrics.glacierTotal;

            localLog(sprintf('Gap-filled: %s | missing %d -> %d -> %d', ...
                char(tileIds(i)), r.metrics.missingOrig, r.metrics.missingAfterMerge, r.metrics.missingAfterModel));
        catch ME
            localLog(sprintf('Gap-fill failed for %s: %s', char(tileIds(i)), ME.message));
            if exist(tempOut, 'file')
                delete(tempOut);
            end
        end
    end

    if nProcessed == 0
        localLog('Gap-fill pass finished: no SPICE tiles processed.');
        return;
    end

    covBefore = 100 * (glacierTotal - missingOrigTotal) / max(glacierTotal, 1);
    covMerge = 100 * (glacierTotal - missingMergeTotal) / max(glacierTotal, 1);
    covModel = 100 * (glacierTotal - missingModelTotal) / max(glacierTotal, 1);

    localLog('Gap-fill pass summary (all processed tiles):');
    localLog(sprintf('  Tiles processed: %d', nProcessed));
    localLog(sprintf('  Missing before fill: %d', missingOrigTotal));
    localLog(sprintf('  Missing after merge: %d', missingMergeTotal));
    localLog(sprintf('  Missing after model: %d', missingModelTotal));
    localLog(sprintf('  Coverage before fill: %.2f%%', covBefore));
    localLog(sprintf('  Coverage after merge: %.2f%%', covMerge));
    localLog(sprintf('  Coverage after model: %.2f%%', covModel));
    localLog('Finished gap-fill pass.');
end

function localClassifySingleTile(tilePath, tileDate, tileId, trainedModel, requiredVars, classNames, glacierMask, glacierShp, outputRoot, overwrite, remapDirtySnowTo, geoData, mod10a1Root, modelPath)
    outPath = fullfile(outputRoot, sprintf('SPICE_%s.nc', char(tileId)));
    if exist(outPath, 'file') && ~overwrite
        localLog(sprintf('Skipping existing output: %s', outPath));
        return;
    end

    try
        localLog(sprintf('Classifying tile: %s', tilePath));
        [bands, spatialRef] = localReadAllBands(tilePath);

        % Cloud mask: prefer MOD10A1 NDSI_Snow_Cover, fall back to MOD09GA state QA.
        [cloudFreeMask, cloudMaskSource] = localGetCloudMask( ...
            tilePath, tileDate, tileId, mod10a1Root, size(glacierMask));

        valid = glacierMask & cloudFreeMask;
        % Only require bands the model actually uses to be finite.
        % Requiring all 7 simultaneously discards many valid pixels when a
        % single SWIR band has fill, even though the model may not need it.
        reqCell = cellstr(requiredVars);
        usedBandNums = [];
        for b = 1:7
            if any(strcmp(reqCell, sprintf('band_%d', b)))
                usedBandNums(end+1) = b; %#ok<AGROW>
            end
        end
        if isempty(usedBandNums); usedBandNums = 1:7; end
        for b = usedBandNums
            valid = valid & isfinite(bands{b});
        end

        idx = find(valid);
        if isempty(idx)
            localLog(sprintf('No valid glacier pixels in tile: %s', tilePath));
            localWriteNetcdf(outPath, tileId, tileDate, glacierShp, classNames, glacierMask, cloudFreeMask, ...
            zeros(size(glacierMask), 'uint8'), requiredVars, cloudMaskSource, modelPath);
            return;
        end

        % ---- Build all computable features ----------------------------------
        allFeats = struct();
        for b = 1:7
            allFeats.(sprintf('band_%d', b)) = bands{b}(idx);
        end

        % Terrain features (NaN when geo mat missing — models not needing them are unaffected)
        allFeats.elevation = geoData.elevation(idx);
        allFeats.slope     = geoData.slope(idx);
        allFeats.aspect    = geoData.aspect(idx);

        % Cyclic day-of-year encoding
        doy  = day(tileDate, 'dayofyear');
        nPix = numel(idx);
        allFeats.time_sin = repmat(sin(2*pi*doy/365), nPix, 1);
        allFeats.time_cos = repmat(cos(2*pi*doy/365), nPix, 1);

        % NDSI: (B4 - B6) / (B4 + B6)
        b4 = bands{4}(idx);  b6 = bands{6}(idx);
        ndsi_v = (b4 - b6) ./ (b4 + b6);
        ndsi_v(~isfinite(ndsi_v)) = NaN;
        allFeats.ndsi = ndsi_v;

        % Band ratios
        r16 = bands{1}(idx) ./ bands{6}(idx);  r16(~isfinite(r16)) = NaN;
        r12 = bands{1}(idx) ./ bands{2}(idx);  r12(~isfinite(r12)) = NaN;
        r26 = bands{2}(idx) ./ bands{6}(idx);  r26(~isfinite(r26)) = NaN;
        allFeats.ratio_b1_b6 = r16;
        allFeats.ratio_b1_b2 = r12;
        allFeats.ratio_b2_b6 = r26;

        % MODIS sinusoidal pixel-centre coordinates.
        % intrinsicToWorld: intrinsicX = column, intrinsicY = row.
        [rowIdx, colIdx] = ind2sub(size(glacierMask), idx);
        [x_s, y_s] = intrinsicToWorld(spatialRef, double(colIdx), double(rowIdx));
        allFeats.x_sinu = x_s(:);
        allFeats.y_sinu = y_s(:);

        % ---- Build predictor table with exactly the columns the model expects
        predCols = cell(1, numel(requiredVars));
        for v = 1:numel(requiredVars)
            vName = char(requiredVars{v});
            if ~isfield(allFeats, vName)
                error('Model requires feature "%s" which cannot be computed for this tile.', vName);
            end
            predCols{v} = allFeats.(vName);
        end
        predictors = table(predCols{:}, 'VariableNames', requiredVars);

        predicted = string(trainedModel.predictFcn(predictors));

        % Optionally remap dirty-snow (os) to snow or ice without retraining.
        if ~isempty(remapDirtySnowTo)
            isDirty = predicted == 'os';
            if any(isDirty)
                predicted(isDirty) = remapDirtySnowTo;
            end
        end

        classId = zeros(size(glacierMask), 'uint8');
        for c = 1:numel(classNames)
            classId(idx(predicted == string(classNames{c}))) = uint8(c);
        end

        localWriteNetcdf(outPath, tileId, tileDate, glacierShp, classNames, glacierMask, cloudFreeMask, ...
            classId, requiredVars, cloudMaskSource, modelPath);
        localLog(sprintf('Wrote: %s', outPath));
    catch ME
        localLog(sprintf('Failed tile %s: %s', tilePath, ME.message));
    end
end

function localWriteNetcdf(outPath, tileId, tileDate, glacierShp, classNames, glacierMask, cloudFreeMask, classId, modelFeatures, cloudMaskSource, modelPath)
    if exist(outPath, 'file')
        delete(outPath);
    end

    [ny, nx] = size(classId);

    nccreate(outPath, 'classification_original', 'Dimensions', {'y', ny, 'x', nx}, 'Datatype', 'int16', 'DeflateLevel', 5);
    ncwrite(outPath, 'classification_original', int16(classId));
    ncwriteatt(outPath, 'classification_original', 'long_name', 'SPICE class id before gap filling');
    ncwriteatt(outPath, 'classification_original', 'description', '0=outside glacier or invalid input; 1..N mapped via class_mapping attribute');

    nccreate(outPath, 'classification_temporal', 'Dimensions', {'y', ny, 'x', nx}, 'Datatype', 'int16', 'DeflateLevel', 5);
    ncwrite(outPath, 'classification_temporal', int16(classId));
    ncwriteatt(outPath, 'classification_temporal', 'long_name', 'SPICE class id after temporal merge (initially equal to original)');

    nccreate(outPath, 'classification_gap_filled', 'Dimensions', {'y', ny, 'x', nx}, 'Datatype', 'int16', 'DeflateLevel', 5);
    ncwrite(outPath, 'classification_gap_filled', int16(classId));
    ncwriteatt(outPath, 'classification_gap_filled', 'long_name', 'SPICE class id after full gap filling (initially equal to original)');

    nccreate(outPath, 'glacier_mask', 'Dimensions', {'y', ny, 'x', nx}, 'Datatype', 'int16', 'DeflateLevel', 5);
    ncwrite(outPath, 'glacier_mask', int16(glacierMask));
    ncwriteatt(outPath, 'glacier_mask', 'long_name', 'Glacier mask (1=inside glacier)');

    nccreate(outPath, 'cloud_free_mask', 'Dimensions', {'y', ny, 'x', nx}, 'Datatype', 'int16', 'DeflateLevel', 5);
    ncwrite(outPath, 'cloud_free_mask', int16(cloudFreeMask));
    ncwriteatt(outPath, 'cloud_free_mask', 'long_name', sprintf('Cloud-free mask from %s (1=cloud-free)', cloudMaskSource));
    ncwriteatt(outPath, 'cloud_free_mask', 'source', cloudMaskSource);

    classMapParts = strings(numel(classNames), 1);
    for i = 1:numel(classNames)
        classMapParts(i) = sprintf('%d:%s', i, classNames{i});
    end

    ncwriteatt(outPath, '/', 'title', 'SPICE MOD09GA glacier-surface classification');
    ncwriteatt(outPath, '/', 'tile_id', char(tileId));
    ncwriteatt(outPath, '/', 'date', char(string(tileDate, 'yyyy-MM-dd')));
    ncwriteatt(outPath, '/', 'glacier_outline_file', glacierShp);
    [~, glacierOutlineName, glacierOutlineExt] = fileparts(glacierShp);
    ncwriteatt(outPath, '/', 'glacier_outline_name', [glacierOutlineName, glacierOutlineExt]);
    ncwriteatt(outPath, '/', 'class_mapping', strjoin(classMapParts, ', '));
    [~, modelBase, modelExt] = fileparts(modelPath);
    ncwriteatt(outPath, '/', 'model_name',     [modelBase, modelExt]);
    ncwriteatt(outPath, '/', 'model_features', strjoin(modelFeatures, ', '));
    ncwriteatt(outPath, '/', 'cloud_mask_source', cloudMaskSource);
    ncwriteatt(outPath, '/', 'gap_fill_applied', int16(0));
    ncwriteatt(outPath, '/', 'gap_fill_summary', 'not_applied');

    localWriteClassMetadata(outPath, strjoin(classMapParts, ', '));
    ncwriteatt(outPath, '/', 'created_utc', char(datetime('now', 'TimeZone', 'UTC', 'Format', 'yyyy-MM-dd''T''HH:mm:ss''Z''')));
end

function [bands, spatialRef] = localReadAllBands(modisFile)
    bands = cell(7, 1);
    spatialRef = [];

    tempDir = fullfile(tempdir, ['mod09ga_read_', char(java.util.UUID.randomUUID)]);
    mkdir(tempDir);
    cleanupHandle = onCleanup(@() rmdir(tempDir, 's'));

    for b = 1:7
        [arr, ref] = localReadSingleBand(modisFile, b, tempDir);
        bands{b} = arr;
        if b == 1
            spatialRef = ref;
        end
    end
end

function [bandArray, readRef] = localReadSingleBand(modisFile, bandNum, tempDir)
    if nargin < 3 || isempty(tempDir)
        tempDir = fullfile(tempdir, ['mod09ga_oneband_', char(java.util.UUID.randomUUID)]);
        mkdir(tempDir);
        cleanupHandle = onCleanup(@() rmdir(tempDir, 's'));
    end

    bandName = sprintf('sur_refl_b%02d_1', bandNum);
    tempTif = fullfile(tempDir, sprintf('band_%02d.tif', bandNum));
    source = sprintf('HDF4_EOS:EOS_GRID:"%s":MODIS_Grid_500m_2D:%s', modisFile, bandName);
    command = sprintf('gdal_translate -q -of GTiff ''%s'' ''%s''', source, tempTif);
    status = system(command);
    if status ~= 0 || ~exist(tempTif, 'file')
        error('gdal_translate failed for %s in %s', bandName, modisFile);
    end

    [bandArray, readRef] = readgeoraster(tempTif);
    bandArray = double(bandArray);
    bandArray(bandArray <= -28672) = NaN;
end

function cloudFreeMask = localReadCloudFreeMask(modisFile, targetSize)
    tempDir = fullfile(tempdir, ['mod09ga_state_', char(java.util.UUID.randomUUID)]);
    mkdir(tempDir);
    cleanupHandle = onCleanup(@() rmdir(tempDir, 's'));

    tempTif = fullfile(tempDir, 'state_1km.tif');
    source = sprintf('HDF4_EOS:EOS_GRID:"%s":MODIS_Grid_1km_2D:state_1km_1', modisFile);
    command = sprintf('gdal_translate -q -of GTiff ''%s'' ''%s''', source, tempTif);
    status = system(command);
    if status ~= 0 || ~exist(tempTif, 'file')
        error('gdal_translate failed for state_1km_1 in %s', modisFile);
    end

    state1km = uint16(readgeoraster(tempTif));

    % MOD09GA state bits: 0-1 cloud state, 2 cloud shadow, 8-9 cirrus.
    cloudState = bitand(state1km, uint16(3));
    isCloudy = (cloudState == 1) | (cloudState == 2);
    hasCloudShadow = bitget(state1km, 3) == 1;
    cirrusState = bitand(bitshift(state1km, -8), uint16(3));
    hasCirrus = cirrusState > 0;

    cloudFree1km = ~(isCloudy | hasCloudShadow | hasCirrus);

    if isequal(size(cloudFree1km), targetSize)
        cloudFreeMask = cloudFree1km;
    elseif size(cloudFree1km, 1) * 2 == targetSize(1) && size(cloudFree1km, 2) * 2 == targetSize(2)
        cloudFreeMask = repelem(cloudFree1km, 2, 2);
    else
        cloudFreeMask = imresize(cloudFree1km, targetSize, 'nearest');
    end

    cloudFreeMask = logical(cloudFreeMask);
end

function glacierMask = localBuildGlacierMask(glacierShp, spatialRef, rasterSize)
    tempDir = fullfile(tempdir, ['glacier_mask_', char(java.util.UUID.randomUUID)]);
    mkdir(tempDir);
    cleanupHandle = onCleanup(@() rmdir(tempDir, 's'));

    reprojShp = fullfile(tempDir, 'glacier_sinu.shp');
    reprojCmd = sprintf(['ogr2ogr -q -overwrite -t_srs "+proj=sinu +R=6371007.181 +units=m +no_defs" ', ...
        '''%s'' ''%s'''], reprojShp, glacierShp);
    status = system(reprojCmd);
    if status ~= 0 || ~exist(reprojShp, 'file')
        error('Failed to reproject glacier outline: %s', glacierShp);
    end

    S = shaperead(reprojShp, 'UseGeoCoords', false);
    glacierMask = false(rasterSize(1), rasterSize(2));

    for k = 1:numel(S)
        x = S(k).X;
        y = S(k).Y;
        valid = ~isnan(x) & ~isnan(y);
        x = x(valid);
        y = y(valid);
        if numel(x) < 3
            continue;
        end

        [xI, yI] = worldToIntrinsic(spatialRef, x, y);
        glacierMask = glacierMask | poly2mask(xI, yI, rasterSize(1), rasterSize(2));
    end
end

function [tileDate, tileId] = localParseModisDateAndTileId(fileName)
    tileDate = NaT;
    tileId = '';

    idToken = regexp(fileName, '^(MOD09GA\.A\d{7}\.h\d{2}v\d{2}\.\d{3})', 'tokens', 'once');
    if ~isempty(idToken)
        tileId = idToken{1};
    end

    dateToken = regexp(fileName, 'MOD09GA\.A(\d{4})(\d{3})\.', 'tokens', 'once');
    if isempty(dateToken)
        return;
    end

    y = str2double(dateToken{1});
    doy = str2double(dateToken{2});
    tileDate = datetime(y, 1, 1) + days(doy - 1);
end

function [selectedShp, selectedYear] = localSelectClosestGlacierOutline(glacierRoot, targetYear)
    shpList = dir(fullfile(glacierRoot, '*_glacier_boundary_polygon.shp'));
    if isempty(shpList)
        error('No *_glacier_boundary_polygon.shp files found in %s', glacierRoot);
    end

    years = nan(numel(shpList), 1);
    for i = 1:numel(shpList)
        tok = regexp(shpList(i).name, '^(\d{4})_glacier_boundary_polygon\.shp$', 'tokens', 'once');
        if ~isempty(tok)
            years(i) = str2double(tok{1});
        end
    end

    valid = ~isnan(years);
    shpList = shpList(valid);
    years = years(valid);
    if isempty(shpList)
        error('Could not parse years from glacier boundary filenames in %s', glacierRoot);
    end

    [~, idx] = min(abs(years - targetYear));
    selectedShp = fullfile(shpList(idx).folder, shpList(idx).name);
    selectedYear = years(idx);
end

function localLog(message)
    fprintf('[%s] %s\n', char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')), message);
end

% =============================================================================
%  CLOUD MASK — MOD10A1 preferred, MOD09GA fallback
% =============================================================================

function [cloudFreeMask, source] = localGetCloudMask(mod09gaPath, tileDate, tileId, mod10a1Root, targetSize)
    % Try MOD10A1 NDSI_Snow_Cover first.
    if ~isempty(mod10a1Root)
        mod10File = localFindMod10a1File(mod10a1Root, tileDate, tileId);
        if ~isempty(mod10File)
            try
                cloudFreeMask = localReadMod10a1CloudMask(mod10File, targetSize);
                source = 'MOD10A1_NDSI_Snow_Cover';
                return;
            catch ME
                localLog(sprintf('MOD10A1 cloud mask failed (%s), falling back to MOD09GA.', ME.message));
            end
        else
            localLog(sprintf('No MOD10A1 file for %s — using MOD09GA state QA.', char(tileId)));
        end
    end
    cloudFreeMask = localReadCloudFreeMask(mod09gaPath, targetSize);
    source = 'MOD09GA_state_1km';
end

function mod10File = localFindMod10a1File(mod10a1Root, tileDate, tileId)
    % Match MOD10A1.AYEARDOY.hXXvYY.0{61|06}.*.hdf for the tile and date.
    tileHV  = regexp(char(tileId), '(h\d{2}v\d{2})', 'match', 'once');
    yearDoy = sprintf('%04d%03d', year(tileDate), day(tileDate, 'dayofyear'));
    for collection = {'061', '006'}
        found = dir(fullfile(mod10a1Root, sprintf('MOD10A1.A%s.%s.%s.*.hdf', yearDoy, tileHV, collection{1})));
        if ~isempty(found)
            mod10File = fullfile(found(1).folder, found(1).name);
            return;
        end
    end
    mod10File = '';
end

function cloudFreeMask = localReadMod10a1CloudMask(mod10File, targetSize)
    % Cloud-free = any valid clear-sky observation.
    % Only value 250 (cloud) and non-retrieval flags are masked out.
    % 201 (no-decision) is kept as cloud-free — it is frequently assigned to
    % glacier surfaces (wet ice, firn, dirty snow) that are not actually cloudy.
    %
    %   0-100  : valid retrieval (land or snow)        → cloud-free ✓
    %   201    : no decision (ambiguous surface)        → cloud-free ✓
    %   211    : night                                  → mask ✗
    %   237    : inland water                           → mask ✗
    %   239    : ocean                                  → mask ✗
    %   250    : CLOUD                                  → mask ✗
    %   253-255: fill / saturated                       → mask ✗
    tempDir = fullfile(tempdir, ['mod10a1_', char(java.util.UUID.randomUUID)]);
    mkdir(tempDir);
    cleanupHandle = onCleanup(@() rmdir(tempDir, 's')); %#ok<NASGU>

    tempTif = fullfile(tempDir, 'ndsi_snow_cover.tif');
    source  = sprintf('HDF4_EOS:EOS_GRID:"%s":MOD_Grid_Snow_500m:NDSI_Snow_Cover', mod10File);
    command = sprintf('gdal_translate -q -of GTiff ''%s'' ''%s''', source, tempTif);
    if system(command) ~= 0 || ~exist(tempTif, 'file')
        error('gdal_translate failed for NDSI_Snow_Cover in %s', mod10File);
    end

    raw = uint8(readgeoraster(tempTif));
    % Clear sky = valid retrieval (0-100) OR no-decision (201 — often glacier surface)
    cloudFreeMask = logical(raw <= 100 | raw == 201);

    if ~isequal(size(cloudFreeMask), targetSize)
        cloudFreeMask = imresize(cloudFreeMask, targetSize, 'nearest');
    end
end

% =============================================================================
%  GEO / DEM helpers  (elevation, slope, aspect from geo_let_it_snow.mat)
% =============================================================================

function geoData = localLoadGeoData(geoMatPath)
    ny = 2400; nx = 2400;
    geoData = struct('elevation', nan(ny, nx), 'slope', nan(ny, nx), 'aspect', nan(ny, nx));

    if ~exist(geoMatPath, 'file')
        localLog(sprintf('WARNING: geo MAT not found: %s — terrain features will be NaN.', geoMatPath));
        return;
    end
    try
        raw = load(geoMatPath);
    catch ME
        localLog(sprintf('WARNING: geo MAT load failed (%s) — terrain features will be NaN.', ME.message));
        return;
    end

    gs = localExtractGeoStruct(raw);
    if isempty(gs); return; end

    elevField   = localFindGeoField(gs, {'elevation','elev','dem','DEM','z','height','alt','altitude'});
    slopeField  = localFindGeoField(gs, {'slope','Slope','SLOPE','gradient','grad'});
    aspectField = localFindGeoField(gs, {'aspect','Aspect','ASPECT','slope_aspect'});

    if ~isempty(elevField)
        rawElev = gs.(elevField);
        if isstruct(rawElev)
            subZ = localFindGeoField(rawElev, {'z','elevation','elev','height','alt'});
            subS = localFindGeoField(rawElev, {'s','slope','Slope','SLOPE','gradient'});
            subA = localFindGeoField(rawElev, {'a','aspect','Aspect','ASPECT','slope_aspect'});
            if ~isempty(subZ)
                geoData.elevation = localResizeGeoArray(double(rawElev.(subZ)), ny, nx);
            end
            if ~isempty(subS) && isempty(slopeField)
                geoData.slope = localResizeGeoArray(double(rawElev.(subS)), ny, nx);
            end
            if ~isempty(subA) && isempty(aspectField)
                geoData.aspect = localResizeGeoArray(double(rawElev.(subA)), ny, nx);
            end
        else
            geoData.elevation = localResizeGeoArray(double(rawElev), ny, nx);
        end
    end
    if ~isempty(slopeField) && ~isstruct(gs.(slopeField))
        geoData.slope = localResizeGeoArray(double(gs.(slopeField)), ny, nx);
    end
    if ~isempty(aspectField) && ~isstruct(gs.(aspectField))
        geoData.aspect = localResizeGeoArray(double(gs.(aspectField)), ny, nx);
    end
    if ~any(isfinite(geoData.slope(:))) && any(isfinite(geoData.elevation(:)))
        localLog('  No slope field — deriving from elevation (MODIS 463.3 m pixels).');
        [dzdx, dzdy] = gradient(geoData.elevation, 463.312716527778);
        geoData.slope = atand(sqrt(dzdx.^2 + dzdy.^2));
    end
end

% =============================================================================
%  PRE-FLIGHT VALIDATION
% =============================================================================

function localValidateModelFeatures(requiredVars, geoData, mod10a1Root, modisRoot, targetYear)
    reqCell = cellstr(requiredVars);
    ok = true;

    % --- terrain features ---
    terrainNeeded = intersect(reqCell, {'elevation','slope','aspect'});
    if ~isempty(terrainNeeded)
        elevOk   = any(isfinite(geoData.elevation(:)));
        slopeOk  = any(isfinite(geoData.slope(:)));
        aspectOk = any(isfinite(geoData.aspect(:)));
        if ~elevOk;   localLog('WARNING: model needs ''elevation'' but geo MAT has no finite elevation values.'); ok = false; end
        if ~slopeOk && any(strcmp(reqCell,'slope'));   localLog('WARNING: model needs ''slope'' but geo MAT has no finite slope values.'); ok = false; end
        if ~aspectOk && any(strcmp(reqCell,'aspect')); localLog('WARNING: model needs ''aspect'' but geo MAT has no finite aspect values.'); ok = false; end
        if elevOk && slopeOk && aspectOk
            localLog('  terrain features (elevation, slope, aspect): OK');
        end
    end

    % --- MOD10A1 cloud mask ---
    % Simple check: any MOD10A1 file for this year?
    nMod10 = numel(dir(fullfile(mod10a1Root, sprintf('MOD10A1.A%d*.hdf', targetYear))));
    if nMod10 == 0
        localLog(sprintf('WARNING: no MOD10A1 files found for year %d in %s — will fall back to MOD09GA state QA for ALL tiles.', targetYear, mod10a1Root));
        ok = false;
    else
        localLog(sprintf('  MOD10A1 cloud mask: %d file(s) found for year %d — OK', nMod10, targetYear));
    end

    % --- cyclic time features ---
    timeNeeded = intersect(reqCell, {'time_sin','time_cos','x_sinu','y_sinu'});
    if ~isempty(timeNeeded)
        localLog('  time_sin / time_cos / x_sinu / y_sinu: always computable from tile — OK');
    end

    % --- band ratios / NDSI ---
    derivedNeeded = intersect(reqCell, {'ndsi','ratio_b1_b6','ratio_b1_b2','ratio_b2_b6'});
    if ~isempty(derivedNeeded)
        localLog(sprintf('  derived features (%s): computed from bands — OK', strjoin(derivedNeeded, ', ')));
    end

    if ok
        localLog('Pre-flight check passed — all required features are available.');
    else
        localLog('Pre-flight check WARNINGS above — some features may be NaN for affected pixels.');
    end
end

function gs = localExtractGeoStruct(raw)
    gs = [];
    if isfield(raw, 'geo') && isstruct(raw.geo); gs = raw.geo; return; end
    f = fieldnames(raw);
    for i = 1:numel(f)
        if isstruct(raw.(f{i})); gs = raw.(f{i}); return; end
    end
    if isfield(raw,'lat') || isfield(raw,'elevation') || isfield(raw,'elev'); gs = raw; end
end

function fname = localFindGeoField(s, candidates)
    fname = '';
    for i = 1:numel(candidates)
        if isfield(s, candidates{i}); fname = candidates{i}; return; end
    end
end

function arr = localResizeGeoArray(arr, ny, nx)
    if isequal(size(arr), [ny, nx]); return; end
    if isequal(size(arr), [nx, ny]); arr = arr'; return; end
    warning('Geo array size %s does not match %dx%d; using as-is.', mat2str(size(arr)), ny, nx);
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

function p = localDefaultGeoMatPath()
    pathLinux = '/data/git/let-it-snow-2/geo/geo_let_it_snow.mat';
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