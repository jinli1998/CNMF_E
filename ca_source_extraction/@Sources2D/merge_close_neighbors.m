function [merged_ROIs, newIDs, obj_bk]  = merge_close_neighbors(obj, show_merge, dmin, method_dist)
%% merge neighboring neurons if they are too close
% inputs:
%   show_merge: boolean scale, manually verify the merging
%   dmin: scalar, minimum distance (pixel)
%   method_dist: str {'max', 'mean'}, method for computing the neuron
%       center. 'max' uses the location of the maximum; 'mean' uses the center
%       of mass

% output:
%   merged_ROIs: cell arrarys, each element contains indices of merged
%   components
%   newIDs: vector, each element is the new index of the merged neurons
%   obj_bk: same as obj, the obj before being merged.

%% Author: Pengcheng Zhou, Carnegie Mellon University.
%  The basic idea is proposed by Eftychios A. Pnevmatikakis: high temporal
%  correlation + spatial overlap
%  reference: Pnevmatikakis et.al.(2016). Simultaneous Denoising, Deconvolution, and Demixing of Calcium Imaging Data. Neuron

%% variables & parameters
fprintf('-------------MERGE CLOSE-BY NEURONS----------\n\n');

A_ = obj.A;          % spatial components
if isempty(obj.C_raw)
    obj.C_raw = obj.C;
end
C_raw_ = obj.C_raw;
C_ = obj.C;

if ~exist('show_merge', 'var') || isempty(show_merge)
    show_merge = false;
end
if show_merge
    cols = [0, 0, 1; 0, 1, 0; 0, 1, 1; 1, 0, 0; 1, 0, 1; 1, 1, 0; 1, 1, 1];
    h_fig = figure('position', [1,1, 1200, 600]);
    stop_show = false;
end
if ~exist('dmin', 'var') || isempty(dmin)
    dmin = obj.options.dmin;
end
deconv_options_0 = obj.options.deconv_options;

%% find neuron pairs to merge
% compute spatial correlation
if ~exist('method_dist', 'var') || isempty(method_dist)
    method_dist = obj.options.method_dist;
end
if any(strcmpi(method_dist, {'mean', 'center'}))
    % use the center of mass as neuron centers. 'center' is an old naming.
    ctr = obj.estCenter();
    yy = ctr(:,1);
    xx = ctr(:,2);
else
    [~,temp] = max(obj.A, [], 1);
    [yy, xx] = ind2sub([obj.options.d1, obj.options.d2], temp);
end
dist_v = sqrt(bsxfun(@minus, xx, xx').^2 + bsxfun(@minus, yy, yy').^2);
temp = bsxfun(@times, obj.A, 1./sqrt(sum(obj.A.^2)));
A_overlap = temp'*temp;
%% using merging criterion to detect paired neurons
flag_merge = (dist_v<=dmin(1)) &(A_overlap>0.8);

% neurons should have similar decaying time constant if we want to merge
% them.
if length(dmin)>1
    max_decay_diff = dmin(2);
    % else
    %     max_decay_diff = 2;
    % end
    K = size(obj.C,1);
    taud = zeros(K, 1);
    for m=1:K
        temp = ar2exp(obj.P.kernel_pars(m));
        taud(m) = temp(1);
    end
    decay_diff = abs(bsxfun(@minus, taud, taud'));
    flag_merge = flag_merge & (decay_diff<max_decay_diff);
end

[l,c] = graph_connected_comp(sparse(flag_merge));     % extract connected components
MC = bsxfun(@eq, reshape(l, [],1), 1:c);
MC(:, sum(MC,1)==1) = [];

%% write log file
% folders and files for saving the results
log_file =  obj.P.log_file;
flog = fopen(log_file, 'a');
log_data = matfile(obj.P.log_data, 'Writable', true); %#ok<NASGU>

fprintf(flog, '[%s]\b', get_minute());
fprintf(flog, 'Start Merging neurons based on neuron distances:\n ');
fprintf(flog, '\tOptions:\n');
fprintf(flog, '\t\tMinimum distance: %.3f\n', dmin);
fprintf(flog, '\t\tMethod for computing neuron center: %s\n', method_dist);

if isempty(MC)
    fprintf('All pairs of neurons are below the merging criterion!\n\n');
    fprintf(flog, '\tAll pairs of neurons are below the merging criterion!\n\n ');
    fclose(flog);
    try
        close(h_fig);
    end
    return;
else
    fprintf('%d neurons will be merged into %d new neurons\n\n', sum(MC(:)), size(MC,2));
    fprintf(flog, '\t%d neurons will be merged into %d new neurons.\n', sum(MC(:)), size(MC,2));
    if show_merge
        fprintf(flog, '\tYou chose to manually verify each merge.\n');
    end
end

%% start merging
obj_bk = obj.copy();
[nr, n2merge] = size(MC);
ind_del = false(nr, 1 );    % indicator of deleting corresponding neurons
merged_ROIs = cell(n2merge,1);
newIDs = zeros(nr, 1);      % indices of the new neurons
k_merged = 0;
k_neurons = 0;
m = 1;
while m <= n2merge
    IDs = find(MC(:, m));   % IDs of neurons within this cluster
    
    % manually verify the merge
    if show_merge && (~stop_show)
        figure(h_fig);
        [tmp_img, col, ~] = obj_bk.overlapA(IDs);
        subplot(221);
        imagesc(tmp_img);
        axis equal off tight;
        subplot(222);
        imagesc(tmp_img);
        axis equal off tight;
        [tmp_r, tmp_c, ~] = find(sum(tmp_img, 3)>0);
        xlim([min(tmp_c)-10, max(tmp_c)+10]);
        ylim([min(tmp_r)-10, max(tmp_r)+10]);
        axis off;
        subplot(2,2,3:4); cla;        
        aa = sum(obj_bk.A(:, IDs),1); 
        tmp_C = obj_bk.C_raw(IDs, :);
        %         tmp_C = bsxfun(@times, tmp_C, 1./max(tmp_C, [], 1));
        for mm=1:size(tmp_C, 1)
            hold on;
            plot(tmp_C(mm,:)*aa(mm), 'color', cols(col(mm), :),  'linewidth', 2);
        end
        temp = input('keep this merge? (y(default)/n(cancel)/back(b)/merge&delete(md)/end showing(e): ', 's');
        if strcmpi(temp, 'n')
            m = m+1;
            continue;
        elseif strcmpi(temp, 'b')
            m = m-1;
            continue; 
        elseif strcmpi(temp, 'e')
            stop_show = true;
        elseif strcmpi(temp, 'md')
            ind_del(IDs) = true;
            m = m+1; 
            continue;
        end
    end
    k_merged = k_merged+1;
    k_neurons = k_neurons+length(IDs);
    merged_ROIs{k_merged} = IDs;
    
    % determine searching area
    active_pixel = (sum(A_(:,IDs), 2)>0);
    
    % update spatial/temporal components of the merged neuron
    data = A_(active_pixel, IDs)*C_raw_(IDs, :);
    ci = C_raw_(IDs(1), :);
    for miter=1:10
        ai = data*ci'/(ci*ci');
        ci = ai'*data/(ai'*ai);
    end
    
    obj.A(active_pixel, IDs(1)) = ai;
    obj.C_raw(IDs(1), :) = ci;
    %     [obj.C(IDs(1), :), obj.S(IDs(1), :), tmp_kernel] = deconvCa(ci, obj.kernel, 3, true, false);
    try
        [obj.C(IDs(1), :), obj.S(IDs(1),:), deconv_options] = deconvolveCa(ci, deconv_options_0);
        obj.P.kernel_pars(IDs(1), :) = deconv_options.pars;
        newIDs(IDs(1)) = IDs(1);
        % remove merged elements
        ind_del(IDs(2:end)) = true;
    catch
        ind_del(IDs) = true;
    end
    m = m+1;
end
newIDs(ind_del) = [];
newIDs = find(newIDs);
merged_ROIs = merged_ROIs(1:k_merged);
%% write to the log file
if isempty(newIDs)
    fprintf('\tYou manually eliminate all merges\n');
    fprintf(flog,'[%s]\bYou have manually eliminate all merges\n', get_minute());
    return;
elseif length(newIDs)==n2merge
    fprintf(flog, '[%s]\bYou approved all merges.\n', get_minute());
else
    fprintf('After manual verification, %d neurons have ben merged into %d new neurons\n\n', k_neurons, k_merged);
    fprintf(flog, '[%s]\bAfter manual verification, %d neurons have ben merged into %d new neurons\n\n', get_minute(), k_neurons, k_merged);
end

merge_results = cell(length(newIDs),1);
for m=1:length(newIDs)
    ind_before = merged_ROIs{m};
    ids_merged = obj_bk.ids(ind_before);
    ind_after = ind_before(1);
    ids_new = obj.ids(ind_after);
    fprintf(flog, '\t\t');
    for k=1:length(ids_merged)
        fprintf(flog, '%d, ', ids_merged(k));
    end
    fprintf(flog, '---> %d\n', ids_new);
    merge_records.before = obj_bk.obj2struct(ind_before);
    merge_records.after = obj.obj2struct(ind_after);
    merge_results{m} = merge_records;
end
% folders and files for saving the results
tmp_str = get_date();
tmp_str=strrep(tmp_str, '-', '_');
eval(sprintf('log_data.merge_%s = merge_results;', tmp_str));
fprintf(flog, '\tThe spatial and temporal components of the merged neurons were saved as intermediate_results.spatial_%s\n', tmp_str);
fprintf(flog, '\tNow the old neurons will be deleted and the merged new ones will replace them.\n\n');
fclose(flog);

% remove merged neurons and update obj
obj.delete(ind_del);
try
    close(h_fig);
end