# Copyright [2013] Hewlett-Packard Development Company, L.P.
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.

#########################################################
#  File graphLoader.R
#
#  
#  Aarsh Fard (afard@vertica.com)
#
#########################################################

## Loading adjaceny matrix from an edgelist strored in a database
# tableName: the name of the table in the database
# from: the name of the column in the table which stores the source vertices
# to: the name of the column in the table which stores the target vertices
# conf: ODBC configuration of the database
# row_wise: if TRUE the returned darray will be row_wise partitioned
# nSplits: number of partitions in darrays (it is an optional argument)
# weight: the name of the column in the table which stores the weights of the edges (it is an optional argument)
db2dgraph <- function(tableName, from, to, conf, weight, nSplits) {
    row_wise <- FALSE   # it is kept for future
    if(!is.character(tableName))
        stop("The name of the table should be specified")
    if(!is.character(from) || !is.character(to))
        stop("The name of the columns for pair of vertices of edge-list should be specified")
    if(is.null(conf))
        stop("The ODBC configuration should be specified")

    if(missing(nSplits)) {
        ps <- distributedR_status()
        nExecuters <- sum(ps$Inst)   # number of executors asked from distributedR
        noBlock2Exc <- 1             # ratio of block numbers to executor numbers
        nparts <- nExecuters * noBlock2Exc  # number of partitions
    } else {
        nSplits <- round(nSplits)
        if(nSplits <= 0)
            stop("nSplits should be a positive integer number")
        nparts <- nSplits
    }

    isWeighted <- FALSE
    if(! missing(weight)) {
        if(!is.character(weight))
            stop("The name of the columns for weight should be character type")
        isWeighted <- TRUE
    }

    # loading vRODBC or RODBC library for master
    if (! require(vRODBC) )
        library(RODBC)
    # connecting to Vertica and finding the number of verices in the table
    connect <- odbcConnect(conf)
    if(isWeighted)
        qryString <- paste("select max(",from,"), max(",to ,"), max(",weight ,") from", tableName)
    else
        qryString <- paste("select max(",from,"), max(",to ,") from", tableName)
    nVertices <- sqlQuery(connect, qryString)
    # check valid response from the database
    if (! is.data.frame(nVertices) ) {
        odbcClose(connect)
        stop(nVertices)
    }
    
    odbcClose(connect)
    
    nVertices <- max(nVertices[[1]],nVertices[[2]]) + 1 # the id of vertices starts from 0
    if(is.na(nVertices)) stop("The content of the table cannot be correctly interpreted! Vertex IDs should be integer numbers.")
    blockSize <- ceiling(nVertices/nparts) # number of rows (columns) in each partition
  
    # creating a sparse darray for adjacency matrix and if needed one for weights
    W <- NULL
    if(row_wise) {
      X <- darray(dim=c(nVertices, nVertices), blocks=c(blockSize,nVertices), sparse=TRUE)
      if(isWeighted)
          W <- darray(dim=c(nVertices, nVertices), blocks=c(blockSize,nVertices), sparse=TRUE)
    } else {
      X <- darray(dim=c(nVertices, nVertices), blocks=c(nVertices,blockSize), sparse=TRUE)
      if(isWeighted)
          W <- darray(dim=c(nVertices, nVertices), blocks=c(nVertices,blockSize), sparse=TRUE)
    }

    if(!missing(nSplits)) {
        nparts <- npartitions(X)
        if(nparts != nSplits)
            warning("The number of splits changed to ", nparts)
    }

    #Load data from Vertica to darray
    if(isWeighted) {
        foreach(i, 1:npartitions(X), initArrays <- function(x = splits(X,i), w = splits(W,i), myIdx = i, blockSize = blockSize, 
                nVertices=nVertices, tableName=tableName, from=from, to=to, weight=weight, conf=conf, row_wise=row_wise) {

            # loading RODBC for each worker
            if (! require(vRODBC) )
                library(RODBC)
            
            if (row_wise) {
                start <- (myIdx-1) * blockSize # start row in the block
                end <- nrow(x) + start         # end row in the block
            } else {
                start <- (myIdx-1) * blockSize # start column in the block
                end <- ncol(x) + start   # end column in the block
            }

            if (row_wise) {
                qryString <- paste("select ",from,",",to,",",weight, " from", tableName, "where ",from," >=", start,"and", from,"<", end)
            } else {
                qryString <- paste("select ",from,",",to,",",weight, " from", tableName, "where ",to," >=", start,"and", to,"<", end)
            }
            # each worker connects to Vertica to load its partition of the darray 
            connect <- odbcConnect(conf)
            segment<-sqlQuery(connect, qryString)
            odbcClose(connect)

            if (row_wise) {
              x <- sparseMatrix(i=segment[[1]]-start, j=segment[[2]], x=1, index1=FALSE, dims=dim(x))
              w <- sparseMatrix(i=segment[[1]]-start, j=segment[[2]], x=segment[[3]], index1=FALSE, dims=dim(x))
            } else {
              x <- sparseMatrix(i=segment[[1]], j=segment[[2]]-start, x=1, index1=FALSE, dims=dim(x))
              w <- sparseMatrix(i=segment[[1]], j=segment[[2]]-start, x=segment[[3]], index1=FALSE, dims=dim(x))
            }
            update(x)
            update(w)
        })
    } else {
        foreach(i, 1:npartitions(X), initArrays <- function(x = splits(X,i), myIdx = i, blockSize = blockSize, 
                nVertices=nVertices, tableName=tableName, from=from, to=to, conf=conf, row_wise=row_wise) {

            # loading RODBC for each worker
            if (! require(vRODBC) )
                library(RODBC)
            
            if (row_wise) {
                start <- (myIdx-1) * blockSize # start row in the block
                end <- nrow(x) + start         # end row in the block
            } else {
                start <- (myIdx-1) * blockSize # start column in the block
                end <- ncol(x) + start   # end column in the block
            }

            if (row_wise) {
                qryString <- paste("select ",from,",",to, " from", tableName, "where ",from," >=", start,"and", from,"<", end)
            } else {
                qryString <- paste("select ",from,",",to, " from", tableName, "where ",to," >=", start,"and", to,"<", end)
            }
            # each worker connects to Vertica to load its partition of the darray 
            connect <- odbcConnect(conf)
            segment<-sqlQuery(connect, qryString, buffsize= end-start)
            odbcClose(connect)

            if (row_wise) {
              x <- sparseMatrix(i=segment[[1]]-start, j=segment[[2]], x=1, index1=FALSE, dims=dim(x))
            } else {
              x <- sparseMatrix(i=segment[[1]], j=segment[[2]]-start, x=1, index1=FALSE, dims=dim(x))
            }
            update(x)
        })
    }

    list(X=X, W=W)
}
# Example:
# dgraphDB <- db2dgraph("graph", from="x", to="y", conf="RDev")

## Loading adjaceny matrix from an edgelist strored in a set of files
# pathPrefix: the path and prefix to the files. It should be the same on all nodes of the cluster.
# nVertices: the total number of vertices in the graph
# verticesInSplit: the number of vertices considered in each split file
# isWeighted: When it is FALSE (defualt) the there is no weight information in the input files
# row_wise: it should be TRUE if the files are split based on the first vertices (source) of the edge list; 
#           FALSE if they are split based on the second vertices (target).
file2dgraph <- function(pathPrefix, nVertices, verticesInSplit, isWeighted) {
    row_wise <- FALSE   # it is kept for future

    if(!is.character(pathPrefix))
        stop("The pathPrefix should be specified.")
    if(!is.numeric(verticesInSplit))
        stop("The number of vertices considered in each split should be specified.")
    if(!is.numeric(nVertices) || nVertices < verticesInSplit) 
        stop("The total number of vertices is not correct.")
    if(!is.logical(row_wise))
        stop("It should be specified whether the files are row_wise partitioned or column_wise.")

    blockSize <- verticesInSplit # number of rows (columns) in each partition

    W <- NULL 
    # creating a sparse darray for adjacency matrix, and when needed for weights
    if(row_wise) {
      X <- darray(dim=c(nVertices, nVertices), blocks=c(blockSize,nVertices), sparse=TRUE)
      if (isWeighted)
        W <- darray(dim=c(nVertices, nVertices), blocks=c(blockSize,nVertices), sparse=TRUE)
    } else {
      X <- darray(dim=c(nVertices, nVertices), blocks=c(nVertices,blockSize), sparse=TRUE)
      if (isWeighted)
        W <- darray(dim=c(nVertices, nVertices), blocks=c(nVertices,blockSize), sparse=TRUE)
    }

    nFiles <- npartitions(X)
    cat("Openning files:\n", paste(pathPrefix,"0\n...until...\n",pathPrefix,nFiles-1,"\n",sep=""))
    errDL <- dlist(nFiles) # collecting error messages

    #Load data from files to darray
    if (isWeighted) {
        foreach(i, 1:npartitions(X), initArrays <- function(x = splits(X,i), w = splits(W,i), myIdx = i, blockSize = blockSize, 
                nVertices=nVertices, pathPrefix=pathPrefix, row_wise=row_wise, erri=splits(errDL, i)) {

            fname <- paste(pathPrefix,myIdx-1,sep="")
            options(scipen=10)  #To ensure that everything is printed as number instead of 1e4 like exp format.
            f <- tryCatch({
                  scan(file=fname,what=list(x=0,y=0,w=0), multi.line =FALSE)
                }, error = function(e){
                  erri <- list(file=fname, error=e)
                  update(erri)
                  NULL
                })
            if(! is.null(f)) {
                if (min(f$x) < 0 || min(f$y) < 0 || max(f$x) > nVertices || max(f$y) > nVertices) {
                    erri <- list(file=fname, error="Found out of the range vertices in the split file")
                    update(erri)
                } else if (row_wise) {
                    start <- (myIdx-1) * blockSize # start row in the block
                    end <- start + nrow(x)
                    if(min(f$x) < start || max(f$x) >= end) {
                        erri <- list(file=fname, error="Error in the range of vertices in the split files")
                        update(erri)
                    } else {
                        x <- sparseMatrix(i=f$x-start, j=f$y, x=1, index1=FALSE, dims=dim(x))
                        w <- sparseMatrix(i=f$x-start, j=f$y, x=f$w, index1=FALSE, dims=dim(x))
                        update(x)
                        update(w)
                    }
                } else {
                    start <- (myIdx-1) * blockSize # start column in the block
                    end <- start + ncol(x)
                    if(min(f$y) < start || max(f$y) >= end) {
                        erri <- list(file=fname, error="Error in the range of vertices in the split files")
                        update(erri)
                    } else {
                        x <- sparseMatrix(i=f$x, j=f$y-start, x=1, index1=FALSE, dims=dim(x))
                        w <- sparseMatrix(i=f$x, j=f$y-start, x=f$w, index1=FALSE, dims=dim(x))
                        update(x)
                        update(w)
                    }
                }                
            }
        })
    } else {
        foreach(i, 1:npartitions(X), initArrays <- function(x = splits(X,i), myIdx = i, blockSize = blockSize, 
                nVertices=nVertices, pathPrefix=pathPrefix, row_wise=row_wise, erri=splits(errDL, i)) {

            fname <- paste(pathPrefix,myIdx-1,sep="")
            options(scipen=10)  #To ensure that everything is printed as number instead of 1e4 like exp format.
            f <- tryCatch({
                  scan(file=fname,what=list(x=0,y=0), multi.line =FALSE)
                }, error = function(e){
                  erri <- list(file=fname, error=e)
                  update(erri)
                  NULL
                })
            if(! is.null(f)) {
                if (min(f$x) < 0 || min(f$y) < 0 || max(f$x) > nVertices || max(f$y) > nVertices) {
                    erri <- list(file=fname, error="Found out of the range vertices in the split file")
                    update(erri)
                } else if (row_wise) {
                    start <- (myIdx-1) * blockSize # start row in the block
                    end <- start + nrow(x)
                    if(min(f$x) < start || max(f$x) >= end) {
                        erri <- list(file=fname, error="Error in the range of vertices in the split files")
                        update(erri)
                    } else {
                        x <- sparseMatrix(i=f$x-start, j=f$y, x=1, index1=FALSE, dims=dim(x))
                        update(x)
                    }
                } else {
                    start <- (myIdx-1) * blockSize # start column in the block
                    end <- start + ncol(x)
                    if(min(f$y) < start || max(f$y) >= end) {
                        erri <- list(file=fname, error="Error in the range of vertices in the split files")
                        update(erri)
                    } else {
                        x <- sparseMatrix(i=f$x, j=f$y-start, x=1, index1=FALSE, dims=dim(x))
                        update(x)
                    }
                }                
                
            }
        })
    }

    errorList <- getpartition(errDL)
    if(! is.null(unlist(errorList))) { # there has been an error
        for( i in 1:length(errorList) ) {
            print(paste(errorList[[i]]))
        }
        stop("Error in reading input files")
    }
    list(X=X, W=W)
}
# Example:
# dgraphF <- file2dgraph("~/temp/test/small", nVertices=14, verticesInSplit=2, isWeighted=FALSE)
