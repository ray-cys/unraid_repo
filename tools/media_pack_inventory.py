"""Bounded read-only completed-download inventory; executed in existing SAB Python."""
import hashlib,json,os,stat,sys

def inventory(folder,root):
    def safe_path(p):
        return isinstance(p,str) and p.startswith('/') and not any(c in p for c in '\x00\n\r\t\\') and os.path.normpath(p)==p
    if not safe_path(folder) or not safe_path(root) or folder==root or not folder.startswith(root+'/'):
        raise ValueError('completed download path is outside the configured root')
    if os.path.realpath(folder)!=folder or os.path.realpath(root)!=root:
        raise ValueError('symlinked completed download path')
    device=os.lstat(folder).st_dev;files=[];directories=[];seen=[];todo=[folder];path_bytes=0
    def identity(s):return ':'.join(str(x) for x in (s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_ctime_ns))
    while todo:
        directory=todo.pop();s=os.lstat(directory)
        if not stat.S_ISDIR(s.st_mode) or s.st_dev!=device:raise ValueError('unsafe directory or filesystem boundary')
        directories.append({'relative':os.path.relpath(directory,folder),'identity':identity(s)})
        if len(directories)>512:raise ValueError('directory inventory budget exceeded')
        seen.append((directory,identity(s)))
        with os.scandir(directory) as entries:
            for entry in entries:
                path=entry.path;s=entry.stat(follow_symlinks=False)
                if s.st_dev!=device or stat.S_ISLNK(s.st_mode):raise ValueError('symlink or filesystem boundary')
                if stat.S_ISDIR(s.st_mode):
                    if not safe_path(path) or len(directories)+len(todo)>=512:raise ValueError('unsafe directory or directory inventory budget exceeded')
                    todo.append(path);continue
                if not stat.S_ISREG(s.st_mode) or s.st_nlink!=1:raise ValueError('non-regular or hard-linked source entry')
                relative=os.path.relpath(path,folder)
                if not safe_path(path) or relative.startswith('../'):raise ValueError('unsafe source filename')
                path_bytes+=len(relative.encode('utf-8'))
                if path_bytes>131072 or len(files)>=800:raise ValueError('file inventory budget exceeded')
                files.append({'relative':relative,'size':s.st_size,'identity':identity(s),'video':os.path.splitext(relative)[1].lower() in ('.mkv','.mp4','.m4v','.avi','.mov','.ts','.m2ts','.wmv','.webm')})
                seen.append((path,identity(s)))
    if sum(f['video'] for f in files)>200:raise ValueError('video inventory budget exceeded')
    for path,expected in seen:
        if identity(os.lstat(path))!=expected:raise ValueError('source changed during inventory')
    data={'folder':folder,'files':sorted(files,key=lambda f:f['relative']),'directories':sorted(directories,key=lambda d:d['relative'])}
    data['fingerprint']=hashlib.sha256(json.dumps(data,sort_keys=True,separators=(',',':')).encode()).hexdigest()
    return {'schema':1,'complete':True,**data}

if __name__=='__main__':
    try:
        request=json.load(sys.stdin);json.dump(inventory(request['folder'],request['root']),sys.stdout,separators=(',',':'));sys.stdout.write('\n')
    except (OSError,ValueError,KeyError,TypeError) as e:
        print('Pack source inventory unverified: '+str(e),file=sys.stderr);sys.exit(1)
