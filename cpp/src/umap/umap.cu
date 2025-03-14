/*
 * Copyright (c) 2021-2022, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "runner.cuh"
#include <cuml/manifold/common.hpp>
#include <cuml/manifold/umap.hpp>
#include <cuml/manifold/umapparams.h>

#include <raft/cuda_utils.cuh>

#include <iostream>

namespace ML {
namespace UMAP {

static const int TPB_X = 256;

void find_ab(const raft::handle_t& handle, UMAPParams* params)
{
  cudaStream_t stream = handle.get_stream();
  UMAPAlgo::find_ab(params, stream);
}

std::unique_ptr<raft::sparse::COO<float, int>> get_graph(
  const raft::handle_t& handle,
  float* X,  // input matrix
  float* y,  // labels
  int n,
  int d,
  knn_indices_dense_t* knn_indices,  // precomputed indices
  float* knn_dists,                  // precomputed distances
  UMAPParams* params)
{
  auto graph = std::make_unique<raft::sparse::COO<float>>(handle.get_stream());
  if (knn_indices != nullptr && knn_dists != nullptr) {
    CUML_LOG_DEBUG("Calling UMAP::get_graph() with precomputed KNN");

    manifold_precomputed_knn_inputs_t<knn_indices_dense_t, float> inputs(
      knn_indices, knn_dists, X, y, n, d, params->n_neighbors);
    if (y != nullptr) {
      UMAPAlgo::_get_graph_supervised<knn_indices_dense_t,
                                      float,
                                      manifold_precomputed_knn_inputs_t<knn_indices_dense_t, float>,
                                      TPB_X>(handle, inputs, params, graph.get());
    } else {
      UMAPAlgo::_get_graph<knn_indices_dense_t,
                           float,
                           manifold_precomputed_knn_inputs_t<knn_indices_dense_t, float>,
                           TPB_X>(handle, inputs, params, graph.get());
    }
    return graph;
  } else {
    manifold_dense_inputs_t<float> inputs(X, y, n, d);
    if (y != nullptr) {
      UMAPAlgo::
        _get_graph_supervised<knn_indices_dense_t, float, manifold_dense_inputs_t<float>, TPB_X>(
          handle, inputs, params, graph.get());
    } else {
      UMAPAlgo::_get_graph<knn_indices_dense_t, float, manifold_dense_inputs_t<float>, TPB_X>(
        handle, inputs, params, graph.get());
    }
    return graph;
  }
}

void refine(const raft::handle_t& handle,
            float* X,
            int n,
            int d,
            raft::sparse::COO<float>* graph,
            UMAPParams* params,
            float* embeddings)
{
  CUML_LOG_DEBUG("Calling UMAP::refine() with precomputed KNN");
  manifold_dense_inputs_t<float> inputs(X, nullptr, n, d);
  UMAPAlgo::_refine<knn_indices_dense_t, float, manifold_dense_inputs_t<float>, TPB_X>(
    handle, inputs, params, graph, embeddings);
}

void fit(const raft::handle_t& handle,
         float* X,
         float* y,
         int n,
         int d,
         knn_indices_dense_t* knn_indices,
         float* knn_dists,
         UMAPParams* params,
         float* embeddings,
         raft::sparse::COO<float, int>* graph)
{
  if (knn_indices != nullptr && knn_dists != nullptr) {
    CUML_LOG_DEBUG("Calling UMAP::fit() with precomputed KNN");

    manifold_precomputed_knn_inputs_t<knn_indices_dense_t, float> inputs(
      knn_indices, knn_dists, X, y, n, d, params->n_neighbors);
    if (y != nullptr) {
      UMAPAlgo::_fit_supervised<knn_indices_dense_t,
                                float,
                                manifold_precomputed_knn_inputs_t<knn_indices_dense_t, float>,
                                TPB_X>(handle, inputs, params, embeddings, graph);
    } else {
      UMAPAlgo::_fit<knn_indices_dense_t,
                     float,
                     manifold_precomputed_knn_inputs_t<knn_indices_dense_t, float>,
                     TPB_X>(handle, inputs, params, embeddings, graph);
    }

  } else {
    manifold_dense_inputs_t<float> inputs(X, y, n, d);
    if (y != nullptr) {
      UMAPAlgo::_fit_supervised<knn_indices_dense_t, float, manifold_dense_inputs_t<float>, TPB_X>(
        handle, inputs, params, embeddings, graph);
    } else {
      UMAPAlgo::_fit<knn_indices_dense_t, float, manifold_dense_inputs_t<float>, TPB_X>(
        handle, inputs, params, embeddings, graph);
    }
  }
}

void fit_sparse(const raft::handle_t& handle,
                int* indptr,
                int* indices,
                float* data,
                size_t nnz,
                float* y,
                int n,
                int d,
                UMAPParams* params,
                float* embeddings,
                raft::sparse::COO<float, int>* graph)
{
  manifold_sparse_inputs_t<int, float> inputs(indptr, indices, data, y, nnz, n, d);
  if (y != nullptr) {
    UMAPAlgo::
      _fit_supervised<knn_indices_sparse_t, float, manifold_sparse_inputs_t<int, float>, TPB_X>(
        handle, inputs, params, embeddings, graph);
  } else {
    UMAPAlgo::_fit<knn_indices_sparse_t, float, manifold_sparse_inputs_t<int, float>, TPB_X>(
      handle, inputs, params, embeddings, graph);
  }
}

void transform(const raft::handle_t& handle,
               float* X,
               int n,
               int d,
               knn_indices_dense_t* knn_indices,
               float* knn_dists,
               float* orig_X,
               int orig_n,
               float* embedding,
               int embedding_n,
               UMAPParams* params,
               float* transformed)
{
  if (knn_indices != nullptr && knn_dists != nullptr) {
    manifold_precomputed_knn_inputs_t<knn_indices_dense_t, float> inputs(
      knn_indices, knn_dists, X, nullptr, n, d, params->n_neighbors);
    UMAPAlgo::_transform<knn_indices_dense_t,
                         float,
                         manifold_precomputed_knn_inputs_t<knn_indices_dense_t, float>,
                         TPB_X>(
      handle, inputs, inputs, embedding, embedding_n, params, transformed);
  } else {
    manifold_dense_inputs_t<float> inputs(X, nullptr, n, d);
    manifold_dense_inputs_t<float> orig_inputs(orig_X, nullptr, orig_n, d);
    UMAPAlgo::_transform<knn_indices_dense_t, float, manifold_dense_inputs_t<float>, TPB_X>(
      handle, inputs, orig_inputs, embedding, embedding_n, params, transformed);
  }
}

void transform_sparse(const raft::handle_t& handle,
                      int* indptr,
                      int* indices,
                      float* data,
                      size_t nnz,
                      int n,
                      int d,
                      int* orig_x_indptr,
                      int* orig_x_indices,
                      float* orig_x_data,
                      size_t orig_nnz,
                      int orig_n,
                      float* embedding,
                      int embedding_n,
                      UMAPParams* params,
                      float* transformed)
{
  manifold_sparse_inputs_t<knn_indices_sparse_t, float> inputs(
    indptr, indices, data, nullptr, nnz, n, d);
  manifold_sparse_inputs_t<knn_indices_sparse_t, float> orig_x_inputs(
    orig_x_indptr, orig_x_indices, orig_x_data, nullptr, orig_nnz, orig_n, d);

  UMAPAlgo::_transform<knn_indices_sparse_t, float, manifold_sparse_inputs_t<int, float>, TPB_X>(
    handle, inputs, orig_x_inputs, embedding, embedding_n, params, transformed);
}

}  // namespace UMAP
}  // namespace ML
