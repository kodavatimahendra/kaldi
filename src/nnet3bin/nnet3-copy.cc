// nnet3bin/nnet3-copy.cc

// Copyright 2012  Johns Hopkins University (author:  Daniel Povey)
//           2015  Xingyu Na

// See ../../COPYING for clarification regarding multiple authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
// THIS CODE IS PROVIDED *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
// WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
// MERCHANTABLITY OR NON-INFRINGEMENT.
// See the Apache 2 License for the specific language governing permissions and
// limitations under the License.

#include <typeinfo>
#include "base/kaldi-common.h"
#include "util/common-utils.h"
#include "hmm/transition-model.h"
#include "nnet3/am-nnet-simple.h"
#include "nnet3/nnet-utils.h"

int main(int argc, char *argv[]) {
  try {
    using namespace kaldi;
    using namespace kaldi::nnet3;
    typedef kaldi::int32 int32;

    const char *usage =
        "Copy 'raw' nnet3 neural network to standard output\n"
        "Also supports setting all the learning rates to a value\n"
        "(the --learning-rate option)\n"
        "\n"
        "Usage:  nnet3-copy [options] <nnet-in> <nnet-out>\n"
        "e.g.:\n"
        " nnet3-copy --binary=false 0.raw text.raw\n";

    bool binary_write = true;
    BaseFloat learning_rate = -1;
    std::string set_nnet = "",
      rename_node_names = "";
    ParseOptions po(usage);
    po.Register("binary", &binary_write, "Write output in binary mode");
    po.Register("learning-rate", &learning_rate,
                "If supplied, all the learning rates of updatable components"
                "are set to this value.");
    po.Register("set-nnet", &set_nnet,
                "Set the nnet inside the model to the one provided in "
                "the option string (interpreted as an rxfilename).  Done "
                "before the learning-rate is changed.");
    po.Register("rename-node-names", &rename_node_names, "Comma-separated list of noed names need to be modified"
                " and their new name. e.g. 'affine0/affine0-lang1,affine1/affine1-lang1'");
    
    po.Read(argc, argv);
    if (po.NumArgs() != 2) {
      po.PrintUsage();
      exit(1);
    }

    std::string raw_nnet_rxfilename = po.GetArg(1),
                raw_nnet_wxfilename = po.GetArg(2);
    
    Nnet nnet;
    if (!set_nnet.empty()) 
      ReadKaldiObject(set_nnet, &nnet);
    else  
      ReadKaldiObject(raw_nnet_rxfilename, &nnet);
     
    if (learning_rate >= 0)
      SetLearningRate(learning_rate, &nnet);
    if (!rename_node_names.empty()) {
      std::vector<string> orig_names, 
        new_names;
      //GetRenameNodeNames(rename_node_names, &orig_names, new_names);
      // separate nodes separated by space.
      std::vector<string> separate_nodes;
      SplitStringToVector(rename_node_names, ",", true, &separate_nodes);
      int32 num_modified = separate_nodes.size();
      for (int32 ind = 0; ind < num_modified; ind++) {
        std::vector<string> rename_node_name;
        SplitStringToVector(separate_nodes[ind], "/", true, &rename_node_name);
        KALDI_ASSERT(rename_node_name.size() == 2);
        // rename node name to new node name. 
        int32 orig_node_index = nnet.GetNodeIndex(rename_node_name[0]);
        if (orig_node_index == -1) 
          KALDI_ERR << "No node with name " << rename_node_name[0]
                    << " is specified in the nnet.";
        nnet.RenameNodeName(orig_node_index, rename_node_name[1]);
      }
    }

    WriteKaldiObject(nnet, raw_nnet_wxfilename, binary_write);
    KALDI_LOG << "Copied raw neural net from " << raw_nnet_rxfilename
              << " to " << raw_nnet_wxfilename;

    return 0;
  } catch(const std::exception &e) {
    std::cerr << e.what() << '\n';
    return -1;
  }
}
