# distutils: language = c++
import numpy as np
from igraph import Graph
from collections import deque
from libcpp.map cimport map as cpp_map
from libcpp.vector cimport vector as cpp_vec
from libcpp.deque cimport deque as cpp_deq
from libcpp cimport bool as bool_t
from syri.bin.func.myUsefulFunctions import *
# from scipy.stats import *
import pandas as pd
from gc import collect
import logging
from datetime import datetime
from syri.pyxFiles.synsearchFunctions import apply_TS, alignmentBlock
from syri.pyxFiles.function cimport getConnectivityGraph

cimport numpy as np

np.random.seed(1)

cpdef invPath(cpp_map[long, cpp_vec[long]] invpos, long[:, :] neighbour, float[:] profit, long[:] aStart, long[:] aEnd, long[:] bStart, long[:] bEnd, long threshold):
    cdef:
        cpp_deq[long]               st, end, stb, endb, path
        long[:]                     parents
        float[:]                    totscore
        Py_ssize_t                  i, j, maxid
        int                         lp = invpos.size()
        float                       maxscore

    for i in range(lp):
        st.push_back(aStart[invpos[i].front()])
        end.push_back(aEnd[invpos[i].back()])
        stb.push_back(bEnd[invpos[i].back()])
        endb.push_back(bStart[invpos[i].front()])


    totscore = profit.copy()
    parents = np.array([-1]*lp, dtype = 'int')

    for i in range(lp):
        for j in range(i, lp):
            if st[j] > end[i]-threshold:
                if stb[j] > endb[i] -threshold:
                    if profit[j] + totscore[i] > totscore[j]:
                        totscore[j] = profit[j] + totscore[i]
                        parents[j] = i


    maxid = -1
    maxscore = -1

    for i in range(lp):
        if totscore[i] > maxscore:
            maxscore = totscore[i]
            maxid = i

    path.push_front(maxid)
    while parents[maxid] != -1:
        path.push_front(parents[maxid])
        maxid = parents[maxid]
    return [path[i] for i in range(<Py_ssize_t> path.size())]

cpdef getProfitable(invblocks, long[:] aStart, long[:] aEnd, long[:] bStart, long[:] bEnd, float[:] iDen, cpp_map[int, cpp_vec[long]] neighbourSyn, float[:] synBlockScore, long[:] aStartSyn, long[:] aEndSyn, long tUC, float tUP,  brk = -1):
    cdef:
        long                            i, j, k, l, current
        long                            n_topo, n_edges, n_syn
        long                            leftSyn, rightSyn, leftEnd, rightEnd, overlapLength
        float                           w, revenue, cost, profit
        Py_ssize_t                      index
        long[:]                         n = np.array(range(len(invblocks)), dtype=np.int)
        long[:]                         topo
        long[:]                         source, target
        long[:]                         pred
        float[:]                        dist
        float[:]                        weight
        long[:,:]                       nsynmap = np.zeros((neighbourSyn.size(), 2), dtype='int64')                  # neighbours of inverted alignments
        cpp_map[long, cpp_deq[long]]    nodepath
        cpp_deq[long]                   path, r_path
        cpp_deq[long]                   startA, endA, startB, endB
        cpp_deq[float]                  iden
        bool_t                          isMore

    n_syn = len(synBlockScore)
    invG = getConnectivityGraph(invblocks)
    out = deque()

    # get neighbours of inverted alignments
    for i in range(<Py_ssize_t> neighbourSyn.size()):
        nsynmap[i, 0] = neighbourSyn[i][0]
        nsynmap[i, 1] = neighbourSyn[i][1]

    ## Get topological ordering of the graph
    indegree = invG.vs.degree('IN')
    q = deque()
    toporder = deque()
    for i in n:
        if indegree[i] == 0:
            q.append(i)

    cnt = 0
    while len(q) > 0:
        u = q.popleft()
        toporder.append(u)
        for i in invG.neighbors(u,'OUT'):
            indegree[i] -= 1
            if indegree[i] == 0:
                q.append(i)
        cnt += 1

    if cnt != len(indegree):
        print('Cycle found')

    topo = np.array(toporder, dtype = np.int)
    n_topo = len(topo)

    # Get order in which the edges need to be transversed
    source = np.zeros_like(invG.es['source'], dtype=int)
    target = np.zeros_like(invG.es['source'], dtype=int)
    weight = np.zeros_like(invG.es['source'], dtype=np.float32)

    index = 0
    garb = invG.get_adjlist('OUT')
    for i in range(n_topo):
        if not len(garb[topo[i]]) > 0:
            continue
        w = invG.es[invG.get_eid(topo[i], garb[topo[i]][0])]['weight']
        for j in range(len(garb[topo[i]])):
            source[index] = topo[i]
            target[index] = garb[topo[i]][j]
            weight[index] = w
            index += 1
    n_edges = len(source)

    # Find shortest path to all other nodes from each node

    for i in n:
        # if i%500 == 0:
        #     print(i, str(datetime.now()))
        nodepath.clear()
        pred = np.array([-1]* <Py_ssize_t> len(n), dtype = np.int)
        dist = np.array([np.float32('inf')]*  <Py_ssize_t> len(n), dtype = np.float32)
        dist[i] = 0

        # Process vertices in topological order
        index = 0
        for j in range(n_topo):
            for k in range(index, n_edges):
                if source[k] != topo[j]:
                    break
                if dist[target[k]] > dist[source[k]] + weight[k]:
                    dist[target[k]] = dist[source[k]] + weight[k]
                    pred[target[k]] = source[k]
                index+=1

        for j in range(n_topo):
            # Find all connected paths which are profitable
            if dist[topo[j]] != float("inf"):
                current = topo[j]
                path.clear()
                while current!=i:
                    if nodepath.count(current) > 0:
                        for index in range(<Py_ssize_t> nodepath[current].size()):
                            path.push_back(nodepath[current][index])
                        # path.extend(nodepath[current].copy())
                        break
                    path.push_back(current)
                    current = pred[current]
                nodepath[topo[j]] = path
                path.push_back(i)
                r_path.clear()

                current = path.size()
                for index in range(<Py_ssize_t> path.size()):
                    r_path.push_back(path[current-index-1])

                # calculate revenue of the identified path
                if r_path.size() == 1:
                    revenue = iDen[r_path[0]]*(aEnd[r_path[0]] - aStart[r_path[0]] + 1 + bStart[r_path[0]] - bEnd[r_path[0]] + 1)
                else:
                    revenue = 0
                    # Initiate by adding coordinates of first alignment
                    startA.push_back(aStart[r_path[0]])
                    endA.push_back(aEnd[r_path[0]])
                    startB.push_back(bEnd[r_path[0]])
                    endB.push_back(bStart[r_path[0]])
                    iden.push_back(iDen[r_path[0]])

                    # Add remaining alignments' coordinates iteratively
                    for k in range(1, current):
                        l = r_path[k]
                        isMore = True if iDen[k] > iden.back() else False
                        if aStart[l] < endA.back():
                            # In case of overlapping bases, choose score of the alignment with higher identity
                            if isMore:
                                endA.pop_back()
                                endA.push_back(aStart[l])
                                startA.push_back(aStart[l])
                                endA.push_back(aEnd[l])
                            else:
                                startA.push_back(endA.back())
                                endA.push_back(aEnd[l])
                        else:
                            startA.push_back(aStart[l])
                            endA.push_back(aEnd[l])

                        if bStart[l] > startB.back():
                            # In case of overlapping bases, choose score of the alignment with higher identity
                            if isMore:
                                startB.pop_back()
                                startB.push_back(bStart[l])
                                startB.push_back(bEnd[l])
                                endB.push_back(bStart[l])
                            else:
                                endB.push_back(startB.back())
                                startB.push_back(bEnd[l])
                        else:
                            startB.push_back(bEnd[l])
                            endB.push_back(bStart[l])
                        iden.push_back(iDen[l])

                    if startA.size() == endA.size() == startB.size() == endB.size() == iden.size():
                        for k in range(<Py_ssize_t> iden.size()):
                            revenue += iden[k]*((endA[k] - startA[k] + 1) + (endB[k] - startB[k] + 1))
                        startA.clear()
                        endA.clear()
                        startB.clear()
                        endB.clear()
                        iden.clear()
                    else:
                        print('ERROR in calculating revenue')

                # Calculate cost of the identified path

                # Get left and right syntenic neighbours
                leftSyn = nsynmap[r_path.front()][0] if nsynmap[r_path.front()][0] < nsynmap[r_path.back()][0] else nsynmap[r_path.back()][0]
                rightSyn = nsynmap[r_path.front()][1] if nsynmap[r_path.front()][1] > nsynmap[r_path.back()][1] else nsynmap[r_path.back()][1]

                #cost of removing all intersecting neighbours
                cost = 0
                for k in range(leftSyn+1, rightSyn):
                    cost += synBlockScore[k]

                # Check whether inversion is overlapping. If yes, then check for uniqueness. If not sufficiently unique, then set high cost.
                leftEnd = aEndSyn[leftSyn] if leftSyn > -1 else 0
                rightEnd = aStartSyn[rightSyn] if rightSyn < n_syn else aEnd[r_path.back()]
                if rightEnd - leftEnd <= tUC:
                    overlapLength = (leftEnd - aStart[r_path.front()]) + (aEnd[r_path.back()] - rightEnd)
                    if (rightEnd - leftEnd)/(aEnd[r_path.back()] - aStart[r_path.front()]) < tUP:
                        cost = 10000000000000

                # Select those candidate inversions for which the score of
                #  adding them would be at least 10% better than the score
                #  of syntenic regions needed to be removed
                if revenue > 1.1*cost:
                    out.append(([r_path[k] for k in range(current)], revenue - cost, leftSyn, rightSyn))
        if i == brk:
            return out
    return out


cpdef getInvBlocks(invTree, invertedCoordsOri):
    cdef int nrow, i, child
    # nrow = invTree.shape[0]
    # invBlocks = [alignmentBlock(i, np.where(invTree.iloc[i,] == True)[0], invertedCoordsOri.iloc[i]) for i in range(nrow)]

    invBlocks = [alignmentBlock(i, invTree[i], invertedCoordsOri.iloc[i]) for i in invTree.keys()]

    for block in invBlocks:
        i = 0
        while(i < len(block.children)):
            block.children = list(set(block.children) - set(invBlocks[block.children[i]].children))
            i+=1
        block.children.sort()

        for child in block.children:
            invBlocks[child].addParent(block.id)
    return(invBlocks)


cpdef dict getNeighbourSyn(np.ndarray aStartInv, np.ndarray aEndInv, np.ndarray bStartInv, np.ndarray bEndInv, np.ndarray indexInv, np.ndarray bDirInv, np.ndarray aStartSyn, np.ndarray aEndSyn, np.ndarray bStartSyn, np.ndarray bEndSyn, np.ndarray indexSyn, np.ndarray bDirSyn, int threshold):
    cdef:
        cdef Py_ssize_t i, j, index
        dict neighbourSyn = dict()
        int upBlock, downBlock
        list upSyn, downSyn
    for i in range(len(indexInv)):
        index = indexInv[i]
        upSyn = np.where(indexSyn < index)[0].tolist()
        downSyn = np.where(indexSyn > index)[0].tolist()

        upBlock  = -1
        downBlock = len(indexSyn)
        for j in upSyn[::-1]:
            if bDirSyn[j] == bDirInv[i]:
                if (aStartInv[i] - aStartSyn[j]) > threshold and (aEndInv[i] - aEndSyn[j]) > threshold and (bStartInv[i] - bStartSyn[j]) > threshold and (bEndInv[i] - bEndSyn[j]) > threshold:
                    upBlock = j
                    break
            else:
                if (aStartInv[i] - aStartSyn[j]) > threshold and (aEndInv[i] - aEndSyn[j]) > threshold and (bEndInv[i] - bStartSyn[j]) > threshold and (bStartInv[i] - bEndSyn[j]) > threshold:
                    upBlock = j
                    break

        for j in downSyn:
            if bDirSyn[j] == bDirInv[i]:
                if (aStartSyn[j] - aStartInv[i]) > threshold and (aEndSyn[j] - aEndInv[i]) > threshold and (bStartSyn[j] - bStartInv[i]) > threshold and (bEndSyn[j] - bEndInv[i]) > threshold:
                    downBlock = j
                    break
            else:
                if (aStartSyn[j] - aStartInv[i]) > threshold and (aEndSyn[j] - aEndInv[i]) > threshold and (bStartSyn[j] - bEndInv[i]) > threshold and (bEndSyn[j] - bStartInv[i]) > threshold:
                    downBlock = j
                    break
        neighbourSyn[i] = [upBlock, downBlock]
    return(neighbourSyn)



def getInversions(coords,chromo, threshold, synData, tUC, tUP):
    logger = logging.getLogger("getinversion."+chromo)

    class inversion:
        def __init__(self, i):
            self.profit = i[1]
            self.neighbours = [i[2], i[3]]
            self.invPos = i[0]

    invertedCoordsOri = coords.loc[(coords.aChr == chromo) & (coords.bChr == chromo) & (coords.bDir == -1)]

    if len(invertedCoordsOri) == 0:
        return(invertedCoordsOri, [],[],invertedCoordsOri,[],[])

    invertedCoords = invertedCoordsOri.copy()
    maxCoords = np.max(np.max(invertedCoords[["bStart","bEnd"]]))

    invertedCoords.bStart = maxCoords + 1 - invertedCoords.bStart
    invertedCoords.bEnd = maxCoords + 1 - invertedCoords.bEnd

    nrow = pd.Series(range(invertedCoords.shape[0]))

    if len(invertedCoordsOri) > 0:
        # invTree = pd.DataFrame(apply_TS(invertedCoords.aStart.values,invertedCoords.aEnd.values,invertedCoords.bStart.values,invertedCoords.bEnd.values, threshold), index = range(len(invertedCoords)), columns = invertedCoords.index.values)
        invTree = apply_TS(invertedCoords.aStart.values,invertedCoords.aEnd.values,invertedCoords.bStart.values,invertedCoords.bEnd.values, threshold)
    else:
        # invTree = pd.DataFrame([], index = range(len(invertedCoords)), columns = invertedCoords.index.values)
        invTree = {}

    logger.debug("found inv Tree " + chromo)

    #######################################################################
    ###### Create list of inverted alignments
    #######################################################################
    invblocks = getInvBlocks(invTree, invertedCoordsOri)
    logger.debug("found inv blocks " + chromo)

    #########################################################################
    ###### Finding profitable inversions (group of inverted blocks)
    #########################################################################

    neighbourSyn = getNeighbourSyn(invertedCoordsOri.aStart.values, invertedCoordsOri.aEnd.values, invertedCoordsOri.bStart.values, invertedCoordsOri.bEnd.values, invertedCoordsOri.index.values, invertedCoordsOri.bDir.values, synData.aStart.values, synData.aEnd.values, synData.bStart.values, synData.bEnd.values, synData.index.values, synData.bDir.values, threshold)

    logger.debug("found neighbours " + chromo)

    synBlockScore = [(i.aLen + i.bLen)*i.iden for index, i in synData.iterrows()]

    ##invPos are 0-indexed positions of inverted alignments in the invertedCoordsOri object
    # profitable = [inversion(cost[i][j], revenue[i][j],
    #                          getNeighbours(neighbourSyn, shortest[i][j]),shortest[i][j])
    #                          for i in range(len(profit)) for j in range(len(profit[i]))\
    #                              if profit[i][j] > (0.1*cost[i][j])]     ##Select only those inversions for which the profit is more than  10% of the cost

    profitable = [inversion(i) for i in getProfitable(invblocks, invertedCoordsOri.aStart.values, invertedCoordsOri.aEnd.values, invertedCoordsOri.bStart.values, invertedCoordsOri.bEnd.values, invertedCoordsOri.iden.values.astype('float32'), neighbourSyn, np.array(synBlockScore, dtype = 'float32'), synData.aStart.values, synData.aEnd.values, tUC, tUP)]

    logger.debug("found profitable " + chromo)

    del(invblocks, invTree, neighbourSyn, synBlockScore)
    collect()
    #####################################################################
    #### Find optimal set of inversions from all profitable inversions
    #####################################################################
    if len(profitable) > 0:
        bestInvPath = invPath({i:profitable[i].invPos for i in range(len(profitable))}, np.array([i.neighbours for i in profitable]), np.array([i.profit for i in profitable], dtype='float32'), invertedCoordsOri.aStart.values, invertedCoordsOri.aEnd.values, invertedCoordsOri.bStart.values, invertedCoordsOri.bEnd.values, threshold)
    else:
        bestInvPath = []

    logger.debug("found bestInvPath " + chromo)

    invBlocksIndex = unlist([profitable[_i].invPos for _i in bestInvPath])
    invData = invertedCoordsOri.iloc[invBlocksIndex]

    badSyn = []
    synInInv = []
    for _i in bestInvPath:
        invNeighbour = profitable[_i].neighbours
#        synInInv = list(range(invNeighbour[0]+1, invNeighbour[1]))
        invPos = profitable[_i].invPos
        invCoord = [invertedCoordsOri.iat[invPos[0],0],invertedCoordsOri.iat[invPos[-1],1],invertedCoordsOri.iat[invPos[-1],3],invertedCoordsOri.iat[invPos[0],2]]
        for _j in range(invNeighbour[0]+1, invNeighbour[1]):
            sd = synData.iloc[_j][["aStart","aEnd","bStart","bEnd"]]
            if (invCoord[0] - sd[0] < threshold) and (sd[1] - invCoord[1] < threshold) and (invCoord[2] - sd[2] < threshold) and (sd[3] - invCoord[2] < threshold):
                synInInv.append(_j)
            else:
                badSyn.append(_j)
    return(invertedCoordsOri, profitable, bestInvPath,invData, synInInv, badSyn)