function [T2, removed] = prepare_training_table_snow_ice_only(varargin)
%PREPARE_TRAINING_TABLE_SNOW_ICE_ONLY Load training table and remove dirty-snow rows.
%   [T2, REMOVED] = PREPARE_TRAINING_TABLE_SNOW_ICE_ONLY() loads the default
%   training table from output/mod09ga_polygon_features.mat, removes all rows
%   where the class label is 'os' (dirty snow), and returns the cleaned table
%   ready for retraining a 2-class (hs/oi) model.
%
%   Name-value options:
%     'TablePath'   Path to training MAT file (default: output/mod09ga_polygon_features.mat)
%     'TableVar'    Variable name inside MAT (default: 'featureTable')
%     'LabelVar'    Name of the label column (default: auto-detect first categorical/string col)
%     'DirtyLabel'  Label value to remove (default: 'os')
%     'SavePath'    If non-empty, save cleaned table to this .mat path (default: '')
%
%   Outputs:
%     T2       Cleaned table with only hs and oi rows
%     removed  Number of rows removed
%
%   Example:
%     T = prepare_training_table_snow_ice_only();
%
%     % Then retrain:
%     mdl = fitctree(T, T.Properties.VariableNames{1}, ...
%         'CrossVal', 'off');
%
%     % Or with the Classification Learner approach:
%     T = prepare_training_table_snow_ice_only('SavePath', ...
%         '/data/joklar/verkefni/2026 - Spectral Glaciers/git/classify-mod09ga-images/output/mod09ga_features_snow_ice_only.mat');

    p = inputParser;
    p.addParameter('TablePath', localDefaultTablePath(), @(x) ischar(x) || isstring(x));
    p.addParameter('TableVar',  'featureTable',          @(x) ischar(x) || isstring(x));
    p.addParameter('LabelVar',  '',                      @(x) ischar(x) || isstring(x));
    p.addParameter('DirtyLabel','os',                    @(x) ischar(x) || isstring(x));
    p.addParameter('SavePath',  '',                      @(x) ischar(x) || isstring(x));
    p.parse(varargin{:});
    args = p.Results;

    tablePath  = char(args.TablePath);
    tableVar   = char(args.TableVar);
    dirtyLabel = char(args.DirtyLabel);
    savePath   = char(args.SavePath);

    if ~exist(tablePath, 'file')
        error('Training MAT file not found: %s', tablePath);
    end

    raw = load(tablePath, tableVar);
    if ~isfield(raw, tableVar)
        % Fallback: try the first variable in the file.
        all = load(tablePath);
        fn  = fieldnames(all);
        raw.(tableVar) = all.(fn{1});
        tableVar = fn{1};
        fprintf('Note: variable ''%s'' not found; loaded ''%s'' instead.\n', char(args.TableVar), tableVar);
    end

    T = raw.(tableVar);
    if ~istable(T)
        error('Loaded variable is not a table (got %s).', class(T));
    end

    % Detect label column.
    labelCol = char(args.LabelVar);
    if isempty(labelCol)
        labelCol = localDetectLabelColumn(T);
    end

    if ~any(strcmp(T.Properties.VariableNames, labelCol))
        error('Label column ''%s'' not found in table. Columns: %s', ...
            labelCol, strjoin(T.Properties.VariableNames, ', '));
    end

    labels = T.(labelCol);
    if iscategorical(labels)
        isDirty = labels == categorical({dirtyLabel});
    else
        isDirty = string(labels) == string(dirtyLabel);
    end

    removed = sum(isDirty);
    T2 = T(~isDirty, :);

    % Remove dirty-snow level from categorical if present.
    if iscategorical(T2.(labelCol))
        T2.(labelCol) = removecats(T2.(labelCol), {dirtyLabel});
    end

    nTotal   = height(T);
    nRemain  = height(T2);
    classes  = unique(string(T2.(labelCol)));
    fprintf('Original rows : %d\n', nTotal);
    fprintf('Removed (os)  : %d (%.1f%%)\n', removed, 100 * removed / nTotal);
    fprintf('Remaining     : %d\n', nRemain);
    fprintf('Classes left  : %s\n', strjoin(classes, ', '));

    if ~isempty(savePath)
        outDir = fileparts(savePath);
        if ~isempty(outDir) && ~exist(outDir, 'dir')
            mkdir(outDir);
        end
        featureTable = T2;
        save(savePath, 'featureTable', '-v7.3');
        fprintf('Saved cleaned table to: %s\n', savePath);
    end
end

function col = localDetectLabelColumn(T)
    % Return first column that is categorical or a string/char array.
    for i = 1:width(T)
        v = T{:, i};
        if iscategorical(v) || iscellstr(v) || isstring(v)
            col = T.Properties.VariableNames{i};
            return;
        end
    end
    error('Could not auto-detect a categorical/string label column. Specify LabelVar explicitly.');
end

function p = localDefaultTablePath()
    % Resolve relative to this file so it works from any working directory.
    here = fileparts(mfilename('fullpath'));
    % helpers/ is one level below the repo root; go up one then into output/.
    repoRoot = fileparts(here);
    p = fullfile(repoRoot, 'output', 'mod09ga_polygon_features.mat');
end
